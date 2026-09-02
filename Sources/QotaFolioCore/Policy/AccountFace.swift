import Foundation

/// One window's level: what is spent of it now, and when it comes back.
///
/// A row on the panel is this and nothing else — the window's name as the provider gave it,
/// the percentage used, the reset instant. Nothing here predicts. The projection lives behind
/// a click, in the instrument, and is a different type (`WindowForecast`).
public nonisolated struct UsageWindowLevel: Hashable, Sendable, Identifiable {
    /// `UsageReading.id` — the provider's own name for the limit and its length. The same key
    /// the history keeps the window's trace under.
    public let id: String
    /// The provider's display name for a scoped limit; `nil` for an account-wide one.
    public let scope: String?
    public let period: UsagePeriod
    /// The row's title: the scope when the provider named one, the window's length otherwise.
    /// Two windows that share a scope take the length after the name, so neither row reads
    /// as the other.
    public let title: String
    /// Percent used, clamped to `0...100`. The only fact on the row.
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(
        id: String,
        scope: String?,
        period: UsagePeriod,
        title: String,
        usedPercent: Double,
        resetsAt: Date?
    ) {
        self.id = id
        self.scope = scope
        self.period = period
        self.title = title
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
    }

    /// Nothing left to spend in this window. The strip's rule, read on the window itself:
    /// the floored remaining percentage is zero.
    public var isSpent: Bool { remainingPercent(fromUsedPercent: usedPercent) == 0 }

    /// A fifth or less of the window left. Apple turns a battery red here, and so does the row.
    public var isLow: Bool { usedPercent >= AccountFace.lowUsedPercent }

    /// The whole number the row prints and VoiceOver reads. Floored, so a window at 37.2 %
    /// reads 37 and never overstates what is gone; a spent window reads 100 whatever the
    /// decimals said, because the bar it sits under is full.
    public var wholePercentUsed: Int {
        isSpent ? 100 : Int(usedPercent.rounded(.down))
    }
}

/// Everything one account's card shows, decided once from the facts the store holds.
///
/// The face is the account's **current usage**: its windows as levels, and the state of the
/// account when there are no levels to draw. It is derived here, in Core, so the card that
/// draws it, the sentence VoiceOver speaks for it and the test that asks a product question
/// of it all read one value.
public nonisolated struct AccountFace: Hashable, Sendable {
    /// What the card's body is, when it is not rows.
    public enum Body: Hashable, Sendable {
        /// One row per window the provider reports, in the order it reports them.
        case windows([UsageWindowLevel])
        /// The grant has lapsed and there is no earlier number to show.
        case needsSignIn
        /// Connected and polling; the first answer has not arrived yet.
        case waitingForFirstReading
        /// The account cannot be polled until it is repaired, and there is no earlier number.
        case setupIssue
        /// The provider answered with nothing usable, and there is no earlier number to show.
        case noReading
    }

    /// Apple turns a battery red at a fifth of its charge left. The strip reads that off what
    /// can be spent right now (`StatusStripModel.lowRemainingPercent` — twenty percent left);
    /// a row reads it off its own window, in the used-language the row is written in: eighty
    /// percent used is a fifth left. A level statement about now, never a prediction.
    public static let lowUsedPercent: Double = 80

    public let body: Body
    /// The plan name the provider printed, e.g. "Max 20x". `nil` when it said nothing.
    public let planName: String?
    /// Whether the grant has lapsed. True with rows too: the last known numbers stay on the
    /// card and the sign-in affordance sits under them.
    public let needsSignIn: Bool
    /// Whether the account cannot be polled until it is repaired. True with rows too.
    public let hasSetupIssue: Bool
    /// The numbers on the card are the last known ones: the poll that would have refreshed
    /// them did not land. The card says so with the instant they were true at.
    public let isLastKnown: Bool
    /// When the numbers on the card were true. `nil` when there are none.
    public let observedAt: Date?
    /// Nothing is spendable now. A spent account's return time is its current state.
    public let isSpent: Bool
    /// When a spent account can be used again, when the provider named the instant.
    public let returnsAt: Date?

    public init(
        body: Body,
        planName: String?,
        needsSignIn: Bool,
        hasSetupIssue: Bool,
        isLastKnown: Bool,
        observedAt: Date?,
        isSpent: Bool,
        returnsAt: Date?
    ) {
        self.body = body
        self.planName = planName
        self.needsSignIn = needsSignIn
        self.hasSetupIssue = hasSetupIssue
        self.isLastKnown = isLastKnown
        self.observedAt = observedAt
        self.isSpent = isSpent
        self.returnsAt = returnsAt
    }

    /// The rows, or none when the body is a state.
    public var windows: [UsageWindowLevel] {
        if case .windows(let levels) = body { return levels }
        return []
    }

    /// The account-wide short window, when the provider reports one.
    public var session: UsageWindowLevel? {
        windows.first { $0.scope == nil && $0.period == .session }
    }

    /// The account-wide weekly window, when the provider reports one.
    public var weekly: UsageWindowLevel? {
        windows.first { $0.scope == nil && $0.period == .weekly }
    }

    /// The face of one account, from what the store knows about it.
    ///
    /// - Parameters:
    ///   - account: the catalog row. Its stored authorization state can call for sign-in even
    ///     when the last poll went through.
    ///   - snapshot: the last reading, if there is one. A snapshot from the other provider
    ///     belongs to a grant this row no longer holds and draws nothing.
    ///   - status: the last poll's outcome, if the account has had one.
    public static func make(
        account: AccountConfig,
        snapshot: UsageSnapshot?,
        status: AccountPollStatus?
    ) -> AccountFace {
        let needsSignIn: Bool = {
            if case .needsReauthentication = account.authorizationState { return true }
            if case .some(.suspendedForReauthentication) = status?.phase { return true }
            return false
        }()
        let hasSetupIssue: Bool = {
            if case .some(.configurationFailure) = status?.phase { return true }
            return false
        }()
        let stale: Bool = {
            if case .some(.stale) = status?.phase { return true }
            return false
        }()

        let reading = snapshot.flatMap { $0.provider == account.provider ? $0 : nil }
        let levels = reading.map(windowLevels(in:)) ?? []

        guard !levels.isEmpty else {
            let body: Body
            if needsSignIn {
                body = .needsSignIn
            } else if hasSetupIssue {
                body = .setupIssue
            } else if stale {
                body = .noReading
            } else {
                body = .waitingForFirstReading
            }
            return AccountFace(
                body: body,
                planName: reading?.planName,
                needsSignIn: needsSignIn,
                hasSetupIssue: hasSetupIssue,
                isLastKnown: false,
                observedAt: nil,
                isSpent: false,
                returnsAt: nil
            )
        }

        // The strip's rule for spent, read from the strip's own arithmetic — `AccountLevel` —
        // so the card and the battery never disagree about an account: what this session lets
        // you spend is the tighter of the session and the week, an account with nothing
        // spendable now is spent, and it comes back when the window that ran dry does. The
        // flags are false because this branch already holds rows: the level here is only the
        // numbers.
        let level = AccountLevel.make(
            provider: account.provider,
            needsSignIn: false,
            hasSetupIssue: false,
            isWaitingForFirstReading: false,
            snapshot: reading
        )
        let isSpent = level.isSpent
        let returnsAt = level.returnsAt

        return AccountFace(
            body: .windows(levels),
            planName: reading?.planName,
            needsSignIn: needsSignIn,
            hasSetupIssue: hasSetupIssue,
            isLastKnown: needsSignIn || hasSetupIssue || stale,
            observedAt: reading?.fetchedAt,
            isSpent: isSpent,
            returnsAt: returnsAt
        )
    }

    /// Every window one snapshot reports, as the rows the card draws, in the order the
    /// provider reports them.
    ///
    /// **The list is not a fixed length.** It is every window the provider sent, titled as the
    /// provider titles it: an account Anthropic has scoped to some other model reads that
    /// model's name, and a metered feature reads the feature's. A window the provider did not
    /// send has no row — nothing is invented. A reading whose number cannot be projected onto
    /// `0...100` is a provider fault and draws no row either.
    public static func windowLevels(in snapshot: UsageSnapshot) -> [UsageWindowLevel] {
        let readings = snapshot.readings.filter {
            remainingPercent(fromUsedPercent: $0.window.usedPercent) != nil
        }
        return titledRows(for: readings).map { titled in
            UsageWindowLevel(
                id: titled.reading.id,
                scope: titled.reading.scope,
                period: titled.reading.period,
                title: titled.title,
                usedPercent: titled.reading.window.usedPercent,
                resetsAt: titled.reading.window.resetsAt
            )
        }
    }
}

/// What one reading is called, on its own: the provider's name when it gave one, and the
/// app's word for the window when it did not.
public nonisolated func usageReadingName(_ reading: UsageReading) -> String {
    reading.scope ?? windowLengthName(reading.period)
}

/// What each row is called.
///
/// The provider's own name, and nothing else — except where one name would draw two rows.
/// A metered feature with both a five-hour and a weekly limit sends two readings under one
/// name, and two rows reading "Spark" tell the user nothing about which is which, so those
/// take the window word after the name.
private nonisolated func titledRows(
    for readings: [UsageReading]
) -> [(reading: UsageReading, title: String)] {
    var counts = [String: Int]()
    for reading in readings where reading.scope != nil {
        counts[reading.scope ?? "", default: 0] += 1
    }

    return readings.map { reading in
        guard let scope = reading.scope else {
            return (reading, windowLengthName(reading.period))
        }
        guard counts[scope, default: 0] > 1 else {
            return (reading, scope)
        }
        return (reading, "\(scope) \(windowLengthName(reading.period))")
    }
}

/// The app's word for a window of a given length.
///
/// The two lengths both providers use today have names; a window this app has no category
/// for is named by its own length, as the system spells it. A provider that adds a thirty-day
/// limit appears the day it ships, reading "30 days", without this app having been taught the
/// word "monthly".
public nonisolated func windowLengthName(_ period: UsagePeriod) -> String {
    switch period {
    case .session:
        return qfLocalized("window.session", defaultValue: "Session", comment: "The provider's short rolling quota window — five hours at both providers today.")
    case .weekly:
        return qfLocalized("window.weekly", defaultValue: "Weekly", comment: "Weekly quota window.")
    case .other(let seconds):
        // `Duration.seconds(_:)` traps on a Double it cannot represent, so the value is
        // bounded here as well as at the parser. `UsagePeriod` is a public type with a
        // Double inside it: this function has to be total for every value that type can
        // hold, not only for the ones today's parsers build.
        let bounded = seconds.isFinite ? min(max(0, seconds), 31_622_400) : 0
        return Duration.seconds(bounded).formatted(
            .units(allowed: [.weeks, .days, .hours, .minutes], width: .wide, maximumUnitCount: 1)
        )
    }
}
