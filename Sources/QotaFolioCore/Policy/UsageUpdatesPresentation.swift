import Foundation

/// What QotaFolio can still say about quota updates for the rest of this run.
///
/// The polling engine can close itself. It does that when one of its own invariants fails — a
/// cancelled flight that never acknowledged, a timer that would not stop — and the closure is
/// permanent for the process: `UsagePollingEngine.start()` refuses to restart a failed-closed
/// engine, and `AccountsStore.start()` refuses in turn. Nothing the user can press reopens it.
///
/// The engine reports that closure by writing `configurationFailure` on every account, which is
/// the truthful phase — the account is not pollable and no retry will change that — but it is not
/// a truthful cause. The user's configuration is fine; the engine terminated. This state carries
/// the cause the phase cannot, so the card can name the right one and the Refresh controls can
/// stop pretending they still do something.
public nonisolated enum UsageUpdatesState: Equatable, Sendable, CaseIterable {
    /// Quota updates are running. Refresh does what its label says.
    case running
    /// Quota updates stopped for this run of QotaFolio and cannot be restarted from inside it.
    case halted
}

/// What the Refresh affordances may do right now.
///
/// Four answers, because four different things are true and each needs a different control.
public nonisolated enum UsageRefreshAvailability: Equatable, Sendable, CaseIterable {
    /// A refresh can be started now.
    case available
    /// A refresh the user asked for is already running. The control shows progress, not refusal.
    case busy
    /// There is no account to refresh.
    case noAccounts
    /// Updates stopped for this run of QotaFolio. A refresh cannot be started at all.
    case halted
}

/// Decides what the Refresh affordances may do, from the three facts that decide it.
///
/// `halted` outranks everything: a stopped engine cannot start a refresh, cannot finish one, and
/// will not become able to. `noAccounts` outranks `busy` because a cohort of nothing is not work
/// in progress.
public nonisolated func usageRefreshAvailability(
    updates: UsageUpdatesState,
    manualRefresh: ManualRefreshActivity?,
    hasRefreshableAccount: Bool
) -> UsageRefreshAvailability {
    if case .halted = updates { return .halted }
    guard hasRefreshableAccount else { return .noAccounts }
    if case .some(.inProgress) = manualRefresh { return .busy }
    return .available
}

/// What a user is told when quota updates have stopped, in the words each surface needs.
///
/// One cause, four surfaces: the card's own well when there are no numbers to show, the banner
/// over the last known numbers when there are, the one sentence every dimmed Refresh control
/// carries as its tooltip and its VoiceOver hint, and the sentence VoiceOver speaks when the state
/// arrives while the panel is open.
///
/// Every one of them names the recovery, and the recovery is real: relaunching the app builds a
/// new engine. None of them mentions Settings, which has nothing about this.
public nonisolated struct UsageUpdatesPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let lastKnownDetail: String
    public let reason: String
    public let spokenSentence: String

    public init(
        title: String,
        detail: String,
        lastKnownDetail: String,
        reason: String,
        spokenSentence: String
    ) {
        self.title = title
        self.detail = detail
        self.lastKnownDetail = lastKnownDetail
        self.reason = reason
        self.spokenSentence = spokenSentence
    }

    /// The presentation for a state that has something to say, or nil while updates are running.
    public static func make(_ state: UsageUpdatesState) -> UsageUpdatesPresentation? {
        switch state {
        case .running:
            return nil
        case .halted:
            return UsageUpdatesPresentation(
                title: qfLocalized(
                    "updates.halted.title",
                    defaultValue: "Updates stopped",
                    comment: "Card heading when the polling engine has stopped for this run of the app."
                ),
                detail: qfLocalized(
                    "updates.halted.detail",
                    defaultValue: "QotaFolio stopped checking your accounts. Your accounts and sign-ins are unchanged. Quit and reopen QotaFolio to start checking again.",
                    comment: "Card body when the polling engine has stopped and no quota numbers are available."
                ),
                lastKnownDetail: qfLocalized(
                    "updates.halted.lastKnown",
                    defaultValue: "Showing last known remaining quota. Quit and reopen QotaFolio to start checking again.",
                    comment: "Card banner over cached quota numbers when the polling engine has stopped."
                ),
                reason: qfLocalized(
                    "updates.halted.reason",
                    defaultValue: "QotaFolio stopped checking your accounts. Quit and reopen QotaFolio to start checking again.",
                    comment: "Tooltip and VoiceOver hint on a Refresh control disabled because the polling engine stopped."
                ),
                spokenSentence: qfLocalized(
                    "updates.halted.sentence",
                    defaultValue: "Updates stopped.",
                    comment: "Complete sentence stating that quota updates have stopped for this run of the app."
                )
            )
        }
    }
}
