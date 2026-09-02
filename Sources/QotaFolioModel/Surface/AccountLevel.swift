import Foundation

/// What one account holds right now, as every surface draws it.
///
/// The strip's battery, the panel's card, the Control's symbol, the widget's ring and the
/// `qota` command all answer the same three questions about an account — how much of its week
/// it still holds, how much of this session it still holds, and whether it has anything it can
/// spend at all. The arithmetic lives here, once, in a target the extension can link, and the
/// words stay where the words are.
///
/// The two windows are two quantities, each measured against its own budget, and neither is
/// expressed in the other's units. Holding a fifth of the week and a half of the session are
/// both true of the same account at the same instant. What the batteries draw is one of them,
/// by the person's own choice; what the words say is both.
///
/// The percentages are whole numbers on purpose. The bar the eye sees and the number a voice
/// reads are then literally the same number.
public nonisolated struct AccountLevel: Hashable, Sendable {
    /// Why an account has nothing to draw. Each case is a different sentence to the user.
    public enum NoReading: Hashable, Sendable {
        /// Connected, polling, and the first answer has not arrived yet.
        case waitingForFirstReading
        /// The grant has lapsed. The user signs in again.
        case needsSignIn
        /// The provider answered with nothing usable, and there is no earlier number to show.
        case unavailable
        /// The account cannot be polled at all until it is repaired.
        case setupIssue
    }

    /// What the account holds, in Apple's own battery language, read off what can be spent
    /// right now: red under a fifth, nothing at all when either window has run dry.
    ///
    /// This is the state the WORDS carry — the tooltip, what VoiceOver reads, the Control's
    /// title, the card's return time and the wake that arms for a reset. The battery is drawn to
    /// whichever quantity the person asked to see, which can be the healthier of the two, so the
    /// picture and this state answer two different questions about one account and both are
    /// true.
    public enum State: Hashable, Sendable {
        /// Something to spend now.
        case reading
        /// A fifth or less of it can be spent now.
        case low
        /// Nothing can be spent now, whatever either window still holds.
        case spent
        /// The outline alone. The reason says why.
        case noReading(NoReading)
    }

    /// A fifth. Apple turns a battery red under a fifth of its charge, and one number serves
    /// both readings of that here: `state` calls an account low when a fifth or less can be
    /// spent right now, and `LevelPalette` turns whatever is drawn red at the same fifth of
    /// itself. So a battery that goes red and an account the app calls low can never drift.
    public static let lowRemainingPercent = 20

    /// The share of the week still held, 0…100.
    public let weeklyRemainingPercent: Int
    /// The share of this five-hour session still held, 0…100 — the session's own window, on its
    /// own budget. A session barely touched reads near a hundred however spent the week is.
    public let sessionRemainingPercent: Int
    public let state: State
    /// When a spent account can be used again, when the provider named the instant.
    public let returnsAt: Date?

    public init(
        weeklyRemainingPercent: Int,
        sessionRemainingPercent: Int,
        state: State,
        returnsAt: Date?
    ) {
        self.weeklyRemainingPercent = weeklyRemainingPercent
        self.sessionRemainingPercent = sessionRemainingPercent
        self.state = state
        self.returnsAt = returnsAt
    }

    public static func noReading(_ reason: NoReading) -> AccountLevel {
        AccountLevel(weeklyRemainingPercent: 0, sessionRemainingPercent: 0, state: .noReading(reason), returnsAt: nil)
    }

    /// What can actually be spent in the next minute: the tighter of the two windows.
    ///
    /// You cannot spend a week you no longer hold, and you cannot spend more this session than
    /// the session allows, so the binding constraint is the smaller number. It is what decides
    /// `state` and what the words are written from. Nothing draws it: a battery drawn to the
    /// tighter of two windows is a battery that answers a question nobody asked.
    public var spendableNowPercent: Int { min(weeklyRemainingPercent, sessionRemainingPercent) }

    public var isSpent: Bool { state == .spent }

    public var hasReading: Bool {
        if case .noReading = state { return false }
        return true
    }

    /// The level of one account, from what is known about it.
    ///
    /// - Parameters:
    ///   - provider: the account's provider. A snapshot from the other provider belongs to a
    ///     grant this row no longer holds and draws nothing.
    ///   - needsSignIn: the grant has lapsed, by the catalog's word or the poller's.
    ///   - hasSetupIssue: the account cannot be polled until it is repaired.
    ///   - isWaitingForFirstReading: connected and polling, no answer yet. Read only when there
    ///     is no snapshot; it decides between "waiting" and "no reading".
    ///   - snapshot: the last reading, if there is one.
    public static func make(
        provider: AccountProvider,
        needsSignIn: Bool,
        hasSetupIssue: Bool,
        isWaitingForFirstReading: Bool,
        snapshot: UsageSnapshot?
    ) -> AccountLevel {
        if needsSignIn { return .noReading(.needsSignIn) }
        if hasSetupIssue { return .noReading(.setupIssue) }

        guard let snapshot, snapshot.provider == provider else {
            return .noReading(isWaitingForFirstReading ? .waitingForFirstReading : .unavailable)
        }

        let weeklyWindow = snapshot.weekly ?? snapshot.session
        let sessionWindow = snapshot.session ?? snapshot.weekly
        guard
            let weeklyWindow,
            let sessionWindow,
            let weekly = remainingPercent(fromUsedPercent: weeklyWindow.usedPercent),
            let session = remainingPercent(fromUsedPercent: sessionWindow.usedPercent)
        else {
            return .noReading(.unavailable)
        }

        // Each window keeps its own number. What can be spent right now is the tighter of the
        // two, and it decides the state and the return time — never a length on screen.
        let spendableNow = min(session, weekly)

        let state: State
        if spendableNow <= 0 {
            state = .spent
        } else if spendableNow <= lowRemainingPercent {
            state = .low
        } else {
            state = .reading
        }

        return AccountLevel(
            weeklyRemainingPercent: weekly,
            sessionRemainingPercent: session,
            state: state,
            // A spent account comes back when the window that ran dry does.
            returnsAt: state == .spent
                ? (weekly <= 0 ? weeklyWindow.resetsAt : sessionWindow.resetsAt)
                : nil
        )
    }
}
