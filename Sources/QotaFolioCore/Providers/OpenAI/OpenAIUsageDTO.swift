import Foundation

/// `GET /backend-api/wham/usage`, decoded field by field.
///
/// This is the endpoint the Codex CLI itself calls, so it is stable in practice — but it is
/// published nowhere and versioned not at all, and OpenAI has already switched the five-hour
/// limit off and back on twice this year. Each window therefore decodes on its own: a slot
/// this app cannot read costs the user that slot and never the response.
nonisolated struct OpenAIUsageEnvelopeDTO: Decodable, Sendable {
  let planType: String?
  let rateLimit: OpenAIRateLimitDTO?
  let additionalRateLimits: [OpenAIAdditionalRateLimitDTO]
  let credits: OpenAICreditsDTO?

  private enum CodingKeys: String, CodingKey {
    case planType = "plan_type"
    case rateLimit = "rate_limit"
    case additionalRateLimits = "additional_rate_limits"
    case credits
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    planType = try? container.decode(String.self, forKey: .planType)
    rateLimit = try? container.decode(OpenAIRateLimitDTO.self, forKey: .rateLimit)
    additionalRateLimits = (try? container.decode([OpenAIAdditionalRateLimitDTO].self, forKey: .additionalRateLimits)) ?? []
    credits = try? container.decode(OpenAICreditsDTO.self, forKey: .credits)
  }
}

nonisolated struct OpenAIRateLimitDTO: Decodable, Sendable {
  let primaryWindow: OpenAIUsageWindowSlotDTO
  let secondaryWindow: OpenAIUsageWindowSlotDTO

  var slots: [OpenAIUsageWindowSlotDTO] { [primaryWindow, secondaryWindow] }

  private enum CodingKeys: String, CodingKey {
    case primaryWindow = "primary_window"
    case secondaryWindow = "secondary_window"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    primaryWindow = Self.decodeSlot(.primaryWindow, from: container)
    secondaryWindow = Self.decodeSlot(.secondaryWindow, from: container)
  }

  private static func decodeSlot(
    _ key: CodingKeys,
    from container: KeyedDecodingContainer<CodingKeys>
  ) -> OpenAIUsageWindowSlotDTO {
    guard container.contains(key) else { return .absent }
    guard (try? container.decodeNil(forKey: key)) != true else { return .absent }
    guard let window = try? container.decode(OpenAIUsageWindowDTO.self, forKey: key) else {
      return .malformed
    }
    return .window(window)
  }
}

/// One per-model or per-feature limit, e.g. GPT-5.3-Codex-Spark.
///
/// `limit_name` and `metered_feature` are both the provider's own naming; whichever it fills
/// in is what the row is called. This app matches no model name and hardcodes none — an
/// entry OpenAI adds appears under the name OpenAI gave it.
nonisolated struct OpenAIAdditionalRateLimitDTO: Decodable, Sendable {
  let limitName: String?
  let meteredFeature: String?
  let rateLimit: OpenAIRateLimitDTO?

  private enum CodingKeys: String, CodingKey {
    case limitName = "limit_name"
    case meteredFeature = "metered_feature"
    case rateLimit = "rate_limit"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    limitName = try? container.decode(String.self, forKey: .limitName)
    meteredFeature = try? container.decode(String.self, forKey: .meteredFeature)
    rateLimit = try? container.decode(OpenAIRateLimitDTO.self, forKey: .rateLimit)
  }
}

nonisolated struct OpenAICreditsDTO: Decodable, Sendable {
  let balance: Double?
  let hasCredits: Bool?

  private enum CodingKeys: String, CodingKey {
    case balance
    case hasCredits = "has_credits"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    balance = try? container.decode(Double.self, forKey: .balance)
    hasCredits = try? container.decode(Bool.self, forKey: .hasCredits)
  }
}

nonisolated enum OpenAIUsageWindowSlotDTO: Sendable {
  case absent
  case malformed
  case window(OpenAIUsageWindowDTO)
}

nonisolated struct OpenAIUsageWindowDTO: Decodable, Sendable {
  let usedPercent: Double?
  let limitWindowSeconds: Double?
  let resetAt: Double?

  private enum CodingKeys: String, CodingKey {
    case usedPercent = "used_percent"
    case limitWindowSeconds = "limit_window_seconds"
    case resetAt = "reset_at"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    usedPercent = try? container.decode(Double.self, forKey: .usedPercent)
    limitWindowSeconds = try? container.decode(Double.self, forKey: .limitWindowSeconds)
    resetAt = try? container.decode(Double.self, forKey: .resetAt)
  }
}
