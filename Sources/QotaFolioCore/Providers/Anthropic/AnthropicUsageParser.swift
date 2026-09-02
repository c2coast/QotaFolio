import Foundation

/// Reads `GET /api/oauth/usage` for everything it says.
///
/// The endpoint carries no version and no contract. Anthropic moved the per-model weekly
/// windows out of the top-level `seven_day_<model>` keys and into `limits[]` in August 2026
/// without telling anybody, and the keys they left behind now answer null. A parser that
/// insists on a shape against an endpoint like that is not strict, it is a scheduled outage.
///
/// So: every window is read on its own. One entry this app cannot use costs the user that
/// entry and nothing else, and a response is refused only when it carried no window at all.
public nonisolated enum AnthropicUsageParser {
  public static func parse(_ body: Data, fetchedAt: Date) throws -> ParsedUsage {
    guard body.count <= AnthropicWire.usageMaxResponseBytes else {
      throw UsageProviderError.invalidPayload
    }

    let envelope: AnthropicUsageEnvelopeDTO
    do {
      envelope = try JSONDecoder().decode(AnthropicUsageEnvelopeDTO.self, from: body)
    } catch {
      throw UsageProviderError.invalidPayload
    }

    var readings = readings(fromLimits: envelope.limits)
    let cameFromLimits = !readings.isEmpty
    readings.append(contentsOf: legacyReadings(envelope.flatWindows, alreadyReported: readings))

    guard !readings.isEmpty else {
      throw UsageProviderError.invalidPayload
    }

    return ParsedUsage(
      snapshot: UsageSnapshot(
        provider: .anthropic,
        readings: readings,
        extraUsage: extraUsage(envelope.extraUsage),
        fetchedAt: fetchedAt
      ),
      schemaFamily: cameFromLimits ? "limits" : "flat"
    )
  }

  // MARK: - limits[]

  /// Projects `limits[]` into readings.
  ///
  /// Two entries of one account-wide kind collapse to the most-constrained of the two — the
  /// one the user runs out of first — because a second session limit is exactly the kind of
  /// thing an undocumented endpoint grows, and losing every bar over it helps nobody.
  ///
  /// Scoped entries do not collapse. Each model keeps its own row, named by the display name
  /// Anthropic sent, so the account whose plan scopes some other model reads that model's
  /// name and that model's number.
  private static func readings(fromLimits limits: [AnthropicUsageLimitDTO]) -> [UsageReading] {
    var session: UsageWindow?
    var weekly: UsageWindow?
    var scoped = [(key: String, reading: UsageReading)]()

    for dto in limits {
      guard let usedPercent = usablePercent(dto.percent) else { continue }
      let window = UsageWindow(
        usedPercent: usedPercent,
        resetsAt: resetDate(dto.resetsAt),
        severity: severity(dto.severity)
      )

      switch classify(dto) {
      case .accountSession:
        session = session.map { moreConstrained($0, window) } ?? window
      case .accountWeekly:
        weekly = weekly.map { moreConstrained($0, window) } ?? window
      case .scoped(let name, let period):
        // One row per model. A repeated model keeps the entry that bites first.
        let key = slug(name)
        if let existing = scoped.firstIndex(where: { $0.key == key }) {
          let kept = moreConstrained(scoped[existing].reading.window, window)
          scoped[existing].reading = UsageReading(scope: name, period: period, window: kept)
        } else {
          scoped.append((key, UsageReading(scope: name, period: period, window: window)))
        }
      case .unusable:
        continue
      }
    }

    var readings = [UsageReading]()
    if let session { readings.append(UsageReading(scope: nil, period: .session, window: session)) }
    if let weekly { readings.append(UsageReading(scope: nil, period: .weekly, window: weekly)) }
    readings.append(contentsOf: scoped.map(\.reading))
    return readings
  }

  private nonisolated enum LimitClassification {
    case accountSession
    case accountWeekly
    case scoped(name: String, period: UsagePeriod)
    case unusable
  }

  /// Decides what one `limits[]` entry is.
  ///
  /// The three kinds Anthropic ships today are named outright. An entry whose kind this app
  /// has never seen is still shown when it names the model it covers — a named number is
  /// worth reading whatever the provider decided to call its category — and dropped only
  /// when there is nothing to title a row with.
  private static func classify(_ dto: AnthropicUsageLimitDTO) -> LimitClassification {
    switch dto.kind {
    case "session":
      return .accountSession
    case "weekly_all":
      return .accountWeekly
    case "weekly_scoped":
      guard let name = scopeName(dto) else { return .unusable }
      return .scoped(name: name, period: .weekly)
    default:
      // An unfamiliar kind is still a number, and a number that names the model it covers
      // can be shown honestly. `group` says how long its window runs; Anthropic's only
      // groups on the wire are "session" and "weekly".
      guard let name = scopeName(dto) else { return .unusable }
      return .scoped(name: name, period: dto.group == "session" ? .session : .weekly)
    }
  }

  /// The model name a scoped entry covers, or nil when it covers everything.
  ///
  /// An "all models" scope is the weekly window under another name, and showing it twice
  /// would tell the user they have two limits where they have one.
  private static func scopeName(_ dto: AnthropicUsageLimitDTO) -> String? {
    guard
      let raw = dto.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
      !raw.isEmpty
    else {
      return nil
    }
    for candidate in [dto.modelID, raw] {
      guard let candidate else { continue }
      let slugged = slug(candidate)
      if slugged == "all-models" || slugged.hasSuffix("-all-models") { return nil }
    }
    return raw
  }

  // MARK: - the legacy top-level windows

  /// Reads the pre-August top-level windows for anything `limits[]` did not report.
  ///
  /// These answer null on every current account. They are read because reading them is free
  /// and because an endpoint that moved a field once can move it back; they are never
  /// required, and they never override a window `limits[]` already reported.
  ///
  /// A top-level window this app has no name for — `iguana_necktie` is the one on the wire
  /// today, undocumented and referenced by no other client — is decoded and not shown. The
  /// app will not invent a label for a number whose meaning nobody knows.
  private static func legacyReadings(
    _ windows: [String: AnthropicFlatWindowDTO],
    alreadyReported: [UsageReading]
  ) -> [UsageReading] {
    guard !windows.isEmpty else { return [] }

    let reportedScopes = Set(alreadyReported.compactMap { $0.scope.map(slug) })
    let hasSession = alreadyReported.contains { $0.scope == nil && $0.period == .session }
    let hasWeekly = alreadyReported.contains { $0.scope == nil && $0.period == .weekly }

    var readings = [UsageReading]()
    for legacy in AnthropicLegacyWindows.all {
      guard let dto = legacy.wireKeys.lazy.compactMap({ windows[$0] }).first else { continue }
      guard let usedPercent = usablePercent(dto.utilization) else { continue }

      switch legacy.scope {
      case .none where hasSession && legacy.period == .session:
        continue
      case .none where hasWeekly && legacy.period == .weekly:
        continue
      case .some(let name) where reportedScopes.contains(slug(name)):
        continue
      default:
        break
      }

      readings.append(
        UsageReading(
          scope: legacy.scope,
          period: legacy.period,
          window: UsageWindow(
            usedPercent: usedPercent,
            resetsAt: resetDate(dto.resetsAt),
            severity: nil
          )
        )
      )
    }
    return readings
  }

  // MARK: - extra_usage

  /// Overage spend, converted out of cents once so nobody downstream has to remember.
  private static func extraUsage(_ dto: AnthropicExtraUsageDTO?) -> ExtraUsage? {
    guard let dto else { return nil }
    guard let usedCents = dto.usedCredits, usedCents.isFinite else { return nil }

    let limitCents = dto.monthlyLimit
    let monthlyLimit = (limitCents?.isFinite == true && (limitCents ?? 0) > 0) ? (limitCents ?? 0) / 100 : nil
    let utilization = dto.utilization.flatMap { $0.isFinite ? $0 : nil }

    return ExtraUsage(
      isEnabled: dto.isEnabled ?? false,
      monthlyLimit: monthlyLimit,
      usedCredits: usedCents / 100,
      utilization: utilization,
      currency: dto.currency
    )
  }

  // MARK: - shared

  private static func usablePercent(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
  }

  /// Keeps whichever of two readings for one window bites the user first.
  private static func moreConstrained(_ lhs: UsageWindow, _ rhs: UsageWindow) -> UsageWindow {
    guard
      let lhsRemaining = remainingPercent(fromUsedPercent: lhs.usedPercent),
      let rhsRemaining = remainingPercent(fromUsedPercent: rhs.usedPercent)
    else {
      return lhs
    }
    let lhsSeverity = effectiveSeverity(providerSeverity: lhs.severity, remainingPercent: lhsRemaining)
    let rhsSeverity = effectiveSeverity(providerSeverity: rhs.severity, remainingPercent: rhsRemaining)
    if lhsSeverity != rhsSeverity { return lhsSeverity > rhsSeverity ? lhs : rhs }
    return lhsRemaining <= rhsRemaining ? lhs : rhs
  }

  private static func severity(_ rawValue: String?) -> UsageSeverity? {
    switch rawValue {
    case "normal":
      .normal
    case "warning":
      .warning
    case "critical":
      .critical
    default:
      nil
    }
  }

  private static func resetDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    return WireValue.date(fromISO8601: value)
  }

  /// Lowercase, hyphen-joined. Used to recognise an all-models scope and to notice that two
  /// entries name one model, never to build anything the user reads.
  private static func slug(_ value: String) -> String {
    var out = ""
    var pendingSeparator = false
    for scalar in value.unicodeScalars {
      if CharacterSet.alphanumerics.contains(scalar) {
        if pendingSeparator, !out.isEmpty { out.append("-") }
        pendingSeparator = false
        out.unicodeScalars.append(scalar)
      } else {
        pendingSeparator = true
      }
    }
    return out.lowercased()
  }
}

/// The top-level windows Anthropic used before August 2026, and the name each one carries.
///
/// Every name here is Anthropic's own — the wire key is the only thing that names these
/// windows, because unlike `limits[]` they carry no `display_name`. A key not in this table
/// is not shown: the app would have to make its label up.
nonisolated enum AnthropicLegacyWindows {
  struct Window: Sendable {
    /// The spellings seen on the wire, tried in order.
    let wireKeys: [String]
    /// The provider's name for the limit, or nil when the window covers the whole account.
    let scope: String?
    let period: UsagePeriod
  }

  static let all: [Window] = [
    Window(wireKeys: ["five_hour"], scope: nil, period: .session),
    Window(wireKeys: ["seven_day"], scope: nil, period: .weekly),
    Window(wireKeys: ["seven_day_opus"], scope: "Opus", period: .weekly),
    Window(wireKeys: ["seven_day_sonnet"], scope: "Sonnet", period: .weekly),
    Window(wireKeys: ["seven_day_oauth_apps"], scope: "OAuth apps", period: .weekly),
    Window(
      wireKeys: [
        "seven_day_routines",
        "seven_day_claude_routines",
        "claude_routines",
        "routines",
        "routine",
        "seven_day_cowork",
        "cowork",
      ],
      scope: "Routines",
      period: .weekly
    ),
  ]
}
