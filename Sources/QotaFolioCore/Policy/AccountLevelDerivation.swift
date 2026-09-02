import Foundation

extension AccountLevel {
    /// The level of one account as the app's own surfaces derive it: the catalog row's word on
    /// the grant, the poller's word on the account, the snapshot's numbers.
    ///
    /// The one place the poll phase becomes the level's flags, so the strip and the surface
    /// relay cannot read the same phase two ways. Surfaces outside the app have no poll phase
    /// — the files carry none — and call `AccountLevel.make` with the catalog's word alone.
    public nonisolated static func make(
        account: AccountConfig,
        snapshot: UsageSnapshot?,
        status: AccountPollStatus?
    ) -> AccountLevel {
        let needsSignIn: Bool = {
            if case .needsReauthentication = account.authorizationState { return true }
            if case .some(.suspendedForReauthentication) = status?.phase { return true }
            return false
        }()
        let hasSetupIssue: Bool = {
            if case .some(.configurationFailure) = status?.phase { return true }
            return false
        }()
        let waiting = status.map { status in
            if case .waitingForFirstSnapshot = status.phase { return true }
            return false
        } ?? true

        return make(
            provider: account.provider,
            needsSignIn: needsSignIn,
            hasSetupIssue: hasSetupIssue,
            isWaitingForFirstReading: waiting,
            snapshot: snapshot
        )
    }
}
