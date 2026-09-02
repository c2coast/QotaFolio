import Foundation

/// Reads `GET /backend-api/wham/usage` for everything it says.
///
/// Two things this parser refuses to do, because both cost the user real numbers:
///
/// 1. **It does not read a window's meaning off the slot it arrived in.** OpenAI disabled the
///    five-hour limit for Plus, Business and Pro in July 2026 and brought it back for Plus on
///    2026-08-25; while a limit is off, the window that survives moves into the primary slot.
///    Every window is classified by `limit_window_seconds`.
/// 2. **It does not require a five-hour window.** Pro 5x and Pro 20x have none today. A
///    single weekly window is a fact about the plan, not a failure to report.
///
/// One unreadable slot never destroys a readable one, and a whole response is refused only
/// when it carried no window this app could read.
public nonisolated enum OpenAIUsageParser {
  public static func parse(_ body: Data, fetchedAt: Date) throws -> ParsedUsage {
    guard body.count <= OpenAIWire.usageMaxResponseBytes else {
      throw UsageProviderError.invalidPayload
    }

    let envelope: OpenAIUsageEnvelopeDTO
    do {
      envelope = try JSONDecoder().decode(OpenAIUsageEnvelopeDTO.self, from: body)
    } catch {
      throw UsageProviderError.invalidPayload
    }

    var readings = [UsageReading]()
    if let rateLimit = envelope.rateLimit {
      readings.append(contentsOf: windowReadings(from: rateLimit, scope: nil))
    }
    for additional in envelope.additionalRateLimits {
      guard let rateLimit = additional.rateLimit, let name = scopeName(additional) else { continue }
      readings.append(contentsOf: windowReadings(from: rateLimit, scope: name))
    }

    guard !readings.isEmpty else {
      throw UsageProviderError.invalidPayload
    }

    return ParsedUsage(
      snapshot: UsageSnapshot(
        provider: .openai,
        readings: readings,
        planName: planName(envelope.planType),
        credits: credits(envelope.credits),
        fetchedAt: fetchedAt
      ),
      schemaFamily: "rate_limit"
    )
  }

  /// Both slots of one `rate_limit` object, in slot order, keeping only what reads.
  private static func windowReadings(from rateLimit: OpenAIRateLimitDTO, scope: String?) -> [UsageReading] {
    var readings = [UsageReading]()
    for slot in rateLimit.slots {
      // `.absent` is a limit this plan does not have. `.malformed` is a slot this app could
      // not decode. Neither says anything about the OTHER slot, so neither ends the loop.
      guard case .window(let dto) = slot else { continue }
      guard
        let usedPercent = dto.usedPercent,
        usedPercent.isFinite,
        usedPercent >= 0,
        let duration = dto.limitWindowSeconds,
        duration.isFinite,
        OpenAIWire.plausibleWindowSecondsRange.contains(duration)
      else {
        continue
      }

      let period: UsagePeriod = if OpenAIWire.sessionWindowSecondsRange.contains(duration) {
        .session
      } else if OpenAIWire.weeklyWindowSecondsRange.contains(duration) {
        .weekly
      } else {
        // A length this app has no name for is still a limit the user is spending against.
        // It is carried with its own duration, and the panel names it by that duration.
        .other(seconds: duration)
      }

      let resetsAt = dto.resetAt.flatMap { timestamp in
        timestamp.isFinite ? Date(timeIntervalSince1970: timestamp) : nil
      }

      // A payload that repeats one period in both slots keeps the reading that bites first,
      // rather than drawing the user two rows for one limit.
      let window = UsageWindow(usedPercent: usedPercent, resetsAt: resetsAt, severity: nil)
      if let existing = readings.firstIndex(where: { $0.period == period }) {
        if usedPercent > readings[existing].window.usedPercent {
          readings[existing] = UsageReading(scope: scope, period: period, window: window)
        }
      } else {
        readings.append(UsageReading(scope: scope, period: period, window: window))
      }
    }
    return readings
  }

  /// What one `additional_rate_limits[]` entry is called.
  ///
  /// `limit_name` is the provider's display spelling and wins; `metered_feature` is the
  /// machine name and stands in when there is no display spelling. An entry that names
  /// itself neither way is dropped — there would be nothing to title its row with.
  private static func scopeName(_ dto: OpenAIAdditionalRateLimitDTO) -> String? {
    for candidate in [dto.limitName, dto.meteredFeature] {
      guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
        continue
      }
      return trimmed
    }
    return nil
  }

  /// The plan, as OpenAI's own clients print it.
  private static func planName(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    switch trimmed.lowercased() {
    case "prolite":
      return "Pro 5x"
    case "pro":
      return "Pro 20x"
    default:
      return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
  }

  /// Flex credits. The count is floored before it is priced, and a negative balance is zero
  /// rather than a refund — that is what the Codex CLI does, and two clients disagreeing
  /// about the same number is worse than either rounding rule.
  private static func credits(_ dto: OpenAICreditsDTO?) -> UsageCredits? {
    guard let balance = dto?.balance, balance.isFinite else { return nil }
    let count = Int(max(0, balance.rounded(.down)))
    return UsageCredits(count: count, dollars: Double(count) * OpenAIWire.creditDollarRate)
  }
}
