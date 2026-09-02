import Foundation

/// One row of the account catalog, as the brain needs it: who the account is, where the
/// person keeps it, and whether its grant still works. No secrets, no network, no store.
public nonisolated struct FleetAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: AccountID
    public let name: String
    public let provider: AccountProvider
    /// The order the person keeps their accounts in. The strip and the panel draw in it, and
    /// so does every list in the assessment.
    public let order: Int
    public let authorizationState: AccountAuthorizationState

    public init(
        id: AccountID,
        name: String,
        provider: AccountProvider,
        order: Int,
        authorizationState: AccountAuthorizationState
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.order = order
        self.authorizationState = authorizationState
    }

    public init(config: AccountConfig) {
        self.init(
            id: config.id,
            name: config.name,
            provider: config.provider,
            order: config.displayOrder,
            authorizationState: config.authorizationState
        )
    }

    public var isConnected: Bool { authorizationState == .connected }
}

/// Everything the app knows about one account right now.
public nonisolated struct AccountAssessment: Equatable, Sendable, Identifiable {
    public let account: FleetAccount
    public var id: AccountID { account.id }

    /// Every window the provider reports, in the order the panel draws them.
    public let windows: [WindowForecast]
    /// Percentage points left in the account's own weekly and session windows.
    public let weeklyRemainingPercent: Double?
    public let sessionRemainingPercent: Double?
    /// Can this account serve right now, and when does it come back if not.
    public let isAvailable: Bool
    public let returnsAt: Date?
    /// How many working sessions the week still funds — or `nil`, which is the app saying
    /// nothing because nothing may honestly be said.
    public let week: WeekPlan?
    /// When this account was last heard from.
    public let observedAt: Date?

    public var session: WindowForecast? {
        windows.first { $0.scope == nil && $0.period == .session }
    }
    public var weekly: WindowForecast? {
        windows.first { $0.scope == nil && $0.period == .weekly }
    }

    public init(
        account: FleetAccount,
        windows: [WindowForecast],
        weeklyRemainingPercent: Double?,
        sessionRemainingPercent: Double?,
        isAvailable: Bool,
        returnsAt: Date?,
        week: WeekPlan?,
        observedAt: Date?
    ) {
        self.account = account
        self.windows = windows
        self.weeklyRemainingPercent = weeklyRemainingPercent
        self.sessionRemainingPercent = sessionRemainingPercent
        self.isAvailable = isAvailable
        self.returnsAt = returnsAt
        self.week = week
        self.observedAt = observedAt
    }
}

/// Something worth interrupting somebody for.
///
/// Each alert carries a key that is stable for as long as the condition is, so the same news
/// is never delivered twice. The key names the condition, the account and the occurrence:
/// a second window running out inside the same occurrence is the same alert, and the same
/// window running out in the next occurrence is a new one.
public nonisolated struct FleetAlert: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// This account reaches its limit before its reset, and another one is free.
        case runningOut(at: Date, windowKey: String, alternative: AccountID?)
        /// A window just turned over, and a fresh one is open.
        case freshWindow(windowKey: String, since: Date)
        /// Quota that will expire unused unless the person spends it.
        case stranding(percent: Double, expiresAt: Date)
    }

    public let kind: Kind
    public let account: AccountID
    /// Stable per condition, per account, per occurrence.
    public let key: String
    public var id: String { key }

    public init(kind: Kind, account: AccountID, key: String) {
        self.kind = kind
        self.account = account
        self.key = key
    }
}

/// **What the app knows, all of it, at one instant.**
///
/// One object: the strip draws from it, the panel draws from it, the sentence is rendered
/// from it, and `recommendation.json` is written from it. There is nothing to keep in step
/// because there is one thing.
public nonisolated struct FleetAssessment: Equatable, Sendable {
    public let generatedAt: Date
    /// In the order the person keeps their accounts in.
    public let accounts: [AccountAssessment]
    public let alerts: [FleetAlert]
    /// The earliest instant at which any of this could be different: a reset, a reading going
    /// stale, or an account coming back. The app asks to be looked at again then, whether or
    /// not a poll is due.
    public let nextReviewAt: Date
    /// When this person works, as measured. Carried because the tooltip and the runway both
    /// draw it, and because it is the evidence behind every number above.
    public let activity: ActivityProfile

    public init(
        generatedAt: Date,
        accounts: [AccountAssessment],
        alerts: [FleetAlert],
        nextReviewAt: Date,
        activity: ActivityProfile
    ) {
        self.generatedAt = generatedAt
        self.accounts = accounts
        self.alerts = alerts
        self.nextReviewAt = nextReviewAt
        self.activity = activity
    }

    /// The fleet, named, with nothing said about it. What the app holds before the first poll
    /// and whenever the brain has nothing honest to say.
    public static func silent(
        at now: Date,
        accounts: [FleetAccount],
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> FleetAssessment {
        empty(at: now, timeZone: timeZone).naming(accounts)
    }

    private func naming(_ fleet: [FleetAccount]) -> FleetAssessment {
        FleetAssessment(
            generatedAt: generatedAt,
            accounts: fleet.sorted { $0.order < $1.order }.map {
                AccountAssessment(
                    account: $0,
                    windows: [],
                    weeklyRemainingPercent: nil,
                    sessionRemainingPercent: nil,
                    isAvailable: false,
                    returnsAt: nil,
                    week: nil,
                    observedAt: nil
                )
            },
            alerts: alerts,
            nextReviewAt: nextReviewAt,
            activity: activity
        )
    }

    public static func empty(at now: Date, timeZone: TimeZone = .autoupdatingCurrent) -> FleetAssessment {
        FleetAssessment(
            generatedAt: now,
            accounts: [],
            alerts: [],
            nextReviewAt: now.addingTimeInterval(BrainPolicy.reviewCeiling),
            activity: .empty(timeZone: timeZone)
        )
    }

    public func assessment(for account: AccountID) -> AccountAssessment? {
        accounts.first { $0.id == account }
    }
}
