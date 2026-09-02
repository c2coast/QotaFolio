import Foundation

/// `GET /api/oauth/usage`, decoded for what it says rather than for a shape agreed in
/// advance.
///
/// The endpoint is undocumented and unversioned. Every field below therefore decodes
/// independently: an addition Anthropic ships on a Tuesday costs the reader that one field
/// and nothing else. There is no top-level `throw` in this file.
nonisolated struct AnthropicUsageEnvelopeDTO: Decodable, Sendable {
  /// The current home of every window, including the per-model weekly ones Anthropic moved
  /// here in August 2026.
  let limits: [AnthropicUsageLimitDTO]

  /// The legacy top-level windows, keyed by the wire name Anthropic gave them. These now
  /// come back null on current accounts; they are read when present and never required.
  let flatWindows: [String: AnthropicFlatWindowDTO]

  /// Overage spend against a monthly cap.
  let extraUsage: AnthropicExtraUsageDTO?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: AnthropicUsageCodingKey.self)

    if
      let key = AnthropicUsageCodingKey(stringValue: "limits"),
      container.contains(key),
      (try? container.decodeNil(forKey: key)) != true
    {
      limits = (try? container.decode([AnthropicUsageLimitDTO].self, forKey: key)) ?? []
    } else {
      limits = []
    }

    if
      let key = AnthropicUsageCodingKey(stringValue: "extra_usage"),
      container.contains(key),
      (try? container.decodeNil(forKey: key)) != true
    {
      extraUsage = try? container.decode(AnthropicExtraUsageDTO.self, forKey: key)
    } else {
      extraUsage = nil
    }

    // Every remaining key whose value is a `{utilization, resets_at}` object is a window.
    // Reading them by shape rather than by an agreed list is what lets a window Anthropic
    // adds appear without a code change; `AnthropicLegacyWindows` decides which of them
    // this app is willing to name and show.
    var windows = [String: AnthropicFlatWindowDTO]()
    for key in container.allKeys where key.stringValue != "limits" && key.stringValue != "extra_usage" {
      guard (try? container.decodeNil(forKey: key)) != true else { continue }
      guard let window = try? container.decode(AnthropicFlatWindowDTO.self, forKey: key) else { continue }
      guard window.utilization != nil else { continue }
      windows[key.stringValue] = window
    }
    flatWindows = windows
  }
}

nonisolated struct AnthropicUsageCodingKey: CodingKey, Sendable {
  let stringValue: String
  var intValue: Int? { nil }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}

nonisolated struct AnthropicFlatWindowDTO: Decodable, Sendable {
  let utilization: Double?
  let resetsAt: String?

  private enum CodingKeys: String, CodingKey {
    case utilization
    case resetsAt = "resets_at"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    utilization = WireValue.double(.utilization, from: container)
    resetsAt = try? container.decode(String.self, forKey: .resetsAt)
  }
}

nonisolated struct AnthropicExtraUsageDTO: Decodable, Sendable {
  let isEnabled: Bool?
  let monthlyLimit: Double?
  let usedCredits: Double?
  let utilization: Double?
  let currency: String?

  private enum CodingKeys: String, CodingKey {
    case isEnabled = "is_enabled"
    case monthlyLimit = "monthly_limit"
    case usedCredits = "used_credits"
    case utilization
    case currency
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = try? container.decode(Bool.self, forKey: .isEnabled)
    monthlyLimit = WireValue.double(.monthlyLimit, from: container)
    usedCredits = WireValue.double(.usedCredits, from: container)
    utilization = WireValue.double(.utilization, from: container)
    currency = try? container.decode(String.self, forKey: .currency)
  }
}

nonisolated struct AnthropicUsageLimitDTO: Decodable, Sendable {
  let kind: String?
  let group: String?
  let percent: Double?
  let severity: String?
  let resetsAt: String?
  /// `scope.model.display_name` — the provider's own name for the model this limit covers.
  let displayName: String?
  /// `scope.model.id` — the stable slug, used to recognise an all-models scope and to
  /// deduplicate two entries for one model.
  let modelID: String?

  private enum CodingKeys: String, CodingKey {
    case kind
    case group
    case percent
    case severity
    case resetsAt = "resets_at"
    case scope
  }

  private enum ScopeKeys: String, CodingKey {
    case model
  }

  private enum ModelKeys: String, CodingKey {
    case id
    case displayName = "display_name"
  }

  init(from decoder: Decoder) throws {
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      kind = nil
      group = nil
      percent = nil
      severity = nil
      resetsAt = nil
      displayName = nil
      modelID = nil
      return
    }

    kind = try? container.decode(String.self, forKey: .kind)
    group = try? container.decode(String.self, forKey: .group)
    severity = try? container.decode(String.self, forKey: .severity)
    percent = WireValue.double(.percent, from: container)
    resetsAt = try? container.decode(String.self, forKey: .resetsAt)

    if
      let scope = try? container.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope),
      let model = try? scope.nestedContainer(keyedBy: ModelKeys.self, forKey: .model)
    {
      displayName = try? model.decode(String.self, forKey: .displayName)
      modelID = try? model.decode(String.self, forKey: .id)
    } else {
      displayName = nil
      modelID = nil
    }
  }
}
