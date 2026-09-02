import Foundation

/// The three quota-window categories the panel and the menu-bar strip draw.
///
/// This is a PRESENTATION vocabulary, not the wire's. `session` and `weekly` are the two
/// windows that belong to the whole account. `fable` is the category of a **model-scoped
/// window**, whatever model the provider has scoped: the case keeps its historic name
/// because the string catalog and the status-item contract are keyed by it, but the row it
/// draws is titled by `UsageReading.scope` — the provider's own display name — so an
/// account scoped to Opus reads "Opus", not "Fable".
public nonisolated enum UsageWindowKind: String, CaseIterable, Sendable { case session, weekly, fable }

/// How long the window one reading measures runs for.
///
/// Classification is by DURATION and never by the slot a payload happened to put a window
/// in. OpenAI moves its remaining window into the primary slot when it disables a limit, so
/// slot position says nothing about which window you are holding.
public nonisolated enum UsagePeriod: Equatable, Hashable, Sendable {
  /// The provider's short rolling window — five hours at both providers today.
  case session
  /// The provider's seven-day window.
  case weekly
  /// A window whose length matches neither of the above. Carried rather than dropped: a
  /// provider that adds a monthly limit should appear in the app the day it ships, named
  /// by its own length.
  case other(seconds: Double)
}

public nonisolated enum UsageSeverity: Equatable, Sendable, Comparable, CaseIterable { case normal, warning, critical }

public nonisolated struct UsageWindow: Equatable, Sendable { public let usedPercent: Double; public let resetsAt: Date?; public let severity: UsageSeverity?
  public init(usedPercent: Double, resetsAt: Date?, severity: UsageSeverity?) { self.usedPercent = usedPercent; self.resetsAt = resetsAt; self.severity = severity } }

/// One quota window exactly as a provider reported it.
///
/// A reading is what the app renders a row from. It carries the provider's own name for the
/// limit rather than a name this app chose, because both providers move their scoped models
/// without notice and a hardcoded model name becomes a lie the day they do.
public nonisolated struct UsageReading: Equatable, Sendable, Identifiable {
  /// The provider's display name for a scoped limit — a model ("Opus 4.6") or a metered
  /// feature ("Spark"). `nil` means the window covers the whole account.
  public let scope: String?

  /// How long the window runs for.
  public let period: UsagePeriod

  /// The reading itself.
  public let window: UsageWindow

  /// The presentation category this reading draws in.
  public var kind: UsageWindowKind {
    guard scope == nil else { return .fable }
    switch period {
    case .session: return .session
    case .weekly: return .weekly
    case .other: return .fable
    }
  }

  /// Stable within one snapshot: scope and period together are what distinguish two rows.
  /// A provider that reports both a five-hour and a weekly limit for one metered feature
  /// yields two readings that share a scope, and they must not collapse into one row.
  public var id: String {
    let periodID: String = switch period {
    case .session: "session"
    case .weekly: "weekly"
    case .other(let seconds): "s\(Int(seconds.rounded()))"
    }
    guard let scope else { return periodID }
    return "\(scope)|\(periodID)"
  }

  public init(scope: String?, period: UsagePeriod, window: UsageWindow) {
    self.scope = scope
    self.period = period
    self.window = window
  }
}

/// Overage spend against a monthly cap, as Anthropic's `extra_usage` object reports it.
///
/// Both figures are DOLLARS here. Anthropic sends cents; the conversion happens once, at the
/// parser, so no reader downstream has to remember which unit it is holding.
public nonisolated struct ExtraUsage: Equatable, Sendable {
  /// Whether the account has overage billing turned on. `false` means the rest is not a
  /// statement about anything the user can spend.
  public let isEnabled: Bool
  /// The monthly cap in dollars, or `nil` when the provider reported no cap.
  public let monthlyLimit: Double?
  /// Spend so far this month, in dollars.
  public let usedCredits: Double
  /// The provider's own percentage of the cap consumed, when it reported one.
  public let utilization: Double?
  /// ISO currency code as the provider spelled it, e.g. `"USD"`.
  public let currency: String?

  public init(isEnabled: Bool, monthlyLimit: Double?, usedCredits: Double, utilization: Double?, currency: String?) {
    self.isEnabled = isEnabled
    self.monthlyLimit = monthlyLimit
    self.usedCredits = usedCredits
    self.utilization = utilization
    self.currency = currency
  }
}

/// Prepaid credits an account can spend once its included quota is gone.
public nonisolated struct UsageCredits: Equatable, Sendable {
  /// The whole number of credits held. Floored before pricing, and never negative, so the
  /// dollar figure matches the one the provider's own client prints.
  public let count: Int
  /// The dollar value of `count`, or `nil` when the app has no rate for this provider.
  public let dollars: Double?

  public init(count: Int, dollars: Double?) {
    self.count = count
    self.dollars = dollars
  }
}

/// Everything one usage response said, in the order the provider said it.
///
/// `readings` is the whole truth. `session`, `weekly` and `fable` are projections of it kept
/// for the callers that ask for one window by name, over a list that can hold as many windows
/// as a provider chooses to send.
public nonisolated struct UsageSnapshot: Equatable, Sendable {
  public let provider: AccountProvider
  /// Every window the provider reported, in the order the app draws them: the account's own
  /// short window, then its weekly window, then every scoped or unfamiliar window in the
  /// order the provider listed them.
  ///
  /// The order is imposed here, once, so that it does not depend on which slot a payload
  /// happened to use or on whether a window came from the current shape or the legacy one.
  public let readings: [UsageReading]
  /// The plan name the provider printed for this account, e.g. `"Pro 20x"`. `nil` when it
  /// said nothing.
  public let planName: String?
  /// Overage spend against a monthly cap, when the provider reports one.
  public let extraUsage: ExtraUsage?
  /// Prepaid credits, when the provider reports them.
  public let credits: UsageCredits?
  public let fetchedAt: Date

  /// The account-wide short window.
  public var session: UsageWindow? { readings.first { $0.scope == nil && $0.period == .session }?.window }

  /// The account-wide weekly window.
  public var weekly: UsageWindow? { readings.first { $0.scope == nil && $0.period == .weekly }?.window }

  /// The model-scoped window that will bite the user first.
  ///
  /// The most-constrained scoped window, whatever the provider named it, so an account
  /// Anthropic has scoped to some other model shows a real number.
  public var fable: UsageWindow? { scopedReadings.first?.window }

  /// Every model- or feature-scoped window, most-constrained first.
  ///
  /// Ties keep report order, and a window that reported no projectable number sorts last
  /// rather than displacing one that did.
  public var scopedReadings: [UsageReading] {
    readings.enumerated()
      .filter { $0.element.scope != nil }
      .sorted { Self.isMoreConstrained($0, $1) }
      .map(\.element)
  }

  public init(
    provider: AccountProvider,
    readings: [UsageReading],
    planName: String? = nil,
    extraUsage: ExtraUsage? = nil,
    credits: UsageCredits? = nil,
    fetchedAt: Date
  ) {
    self.provider = provider
    self.readings = Self.inDrawingOrder(readings)
    self.planName = planName
    self.extraUsage = extraUsage
    self.credits = credits
    self.fetchedAt = fetchedAt
  }

  /// The three-window spelling, kept so a caller that builds a snapshot by naming its
  /// windows does not have to know about readings.
  public init(
    provider: AccountProvider,
    session: UsageWindow?,
    weekly: UsageWindow?,
    fable: UsageWindow?,
    fetchedAt: Date
  ) {
    var readings = [UsageReading]()
    if let session { readings.append(UsageReading(scope: nil, period: .session, window: session)) }
    if let weekly { readings.append(UsageReading(scope: nil, period: .weekly, window: weekly)) }
    if let fable { readings.append(UsageReading(scope: "Fable", period: .weekly, window: fable)) }
    self.init(provider: provider, readings: readings, fetchedAt: fetchedAt)
  }

  /// The account's own windows first, shortest first, then everything the provider named.
  private static func inDrawingOrder(_ readings: [UsageReading]) -> [UsageReading] {
    let accountWide = readings.filter { $0.scope == nil }
    let session = accountWide.first { $0.period == .session }
    let weekly = accountWide.first { $0.period == .weekly }
    let rest = readings.filter { reading in
      reading.id != session?.id && reading.id != weekly?.id
    }
    return [session, weekly].compactMap { $0 } + rest
  }

  /// Orders two readings by which one the user runs out of first: the provider's own
  /// severity leads, then the smaller remaining share, then report order.
  ///
  /// A reading with no projectable number is ordered LAST against every reading that has
  /// one, rather than treated as equivalent to all of them. Equivalence there is not
  /// transitive, and an intransitive predicate is what makes a sort produce an order
  /// nobody asked for.
  private static func isMoreConstrained(
    _ lhs: (offset: Int, element: UsageReading),
    _ rhs: (offset: Int, element: UsageReading)
  ) -> Bool {
    let lhsRemaining = remainingPercent(fromUsedPercent: lhs.element.window.usedPercent)
    let rhsRemaining = remainingPercent(fromUsedPercent: rhs.element.window.usedPercent)

    switch (lhsRemaining, rhsRemaining) {
    case (nil, nil):
      return lhs.offset < rhs.offset
    case (nil, .some):
      return false
    case (.some, nil):
      return true
    case (.some(let lhsValue), .some(let rhsValue)):
      let lhsSeverity = effectiveSeverity(providerSeverity: lhs.element.window.severity, remainingPercent: lhsValue)
      let rhsSeverity = effectiveSeverity(providerSeverity: rhs.element.window.severity, remainingPercent: rhsValue)
      if lhsSeverity != rhsSeverity { return lhsSeverity > rhsSeverity }
      if lhsValue != rhsValue { return lhsValue < rhsValue }
      return lhs.offset < rhs.offset
    }
  }
}
