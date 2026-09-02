import Foundation
import QotaFolioCore

nonisolated struct PollReport: Equatable, Sendable {
    let accountID: AccountID
    /// Which version of this account the report is about.
    ///
    /// The store mints it and hands it to the engine with every operation that changes what an
    /// account *is* — added, signed out, reconnected, removed. The engine stamps it on every
    /// report. `AccountsStore.receive` admits a report when this equals the epoch it currently
    /// holds, and that one comparison is the whole of "is this still the account I asked
    /// about?": a flight from a grant the user has replaced, a suspension answered after a
    /// Remove, a report from an account that no longer exists — all the same question.
    let epoch: UInt64
    let phase: AccountPollPhase
    let isRefreshing: Bool
    let lastAttemptAt: Date?
    let lastSuccessAt: Date?
    let snapshot: SnapshotDisposition
    let lastRequestStartedAt: PollInstant?
    let cachedAt: PollInstant?
    let backoffUntil: PollInstant?
    let consecutiveFailures: Int
}

nonisolated enum SnapshotDisposition: Equatable, Sendable {
    case unchanged
    case replaced(UsageSnapshot)
    case cleared
}

nonisolated struct PollingActivityIdentity: Equatable, Hashable, Sendable {
    let accountID: AccountID
    let runEpoch: UInt64
    let flightID: UInt64
    /// What started this flight.
    ///
    /// Carried here rather than remembered by the store, because the store would be keeping a
    /// second copy of something the flight already knows — and a copy that goes stale the first
    /// time two flights for one account overlap. `AccountsStore.updateActivityLease` reads it to
    /// decide what the process asserts to App Nap while the flight is in the air.
    let trigger: PollTrigger
}

@MainActor protocol PollReporting: AnyObject, Sendable {
    func receive(_ report: PollReport)
    func manualParticipantSettled(_ id: AccountID, cycle: UInt64)
    func pollingActivityDidBegin(_ activity: PollingActivityIdentity)
    func pollingActivityDidEnd(_ activity: PollingActivityIdentity)
}

@MainActor extension PollReporting {
    func pollingActivityDidBegin(_ activity: PollingActivityIdentity) {
        _ = activity
    }

    func pollingActivityDidEnd(_ activity: PollingActivityIdentity) {
        _ = activity
    }
}

nonisolated protocol UsagePollingEngineDriving: Sendable {
    func attach(_ reporter: any PollReporting) async
    func reprojectRateLimitWallDates() async
    func poll(_ id: AccountID, trigger: PollTrigger, manualCycle: UInt64?) async
    func poll(
        _ id: AccountID,
        trigger: PollTrigger,
        manualCycle: UInt64?,
        activityRunEpoch: UInt64
    ) async
    /// Establishes accounts, each carrying the epoch the store holds for it. Every report the
    /// engine makes about an account is stamped with the last epoch it was handed.
    func upsert(_ accounts: [AccountConfig], epochs: [AccountID: UInt64]) async
    func suspend(_ id: AccountID, epoch: UInt64) async
    func resetLineage(_ id: AccountID, revision: CredentialRevision, epoch: UInt64) async
    func remove(_ id: AccountID) async
    func stopAll() async
}

nonisolated extension UsagePollingEngineDriving {
    func poll(
        _ id: AccountID,
        trigger: PollTrigger,
        manualCycle: UInt64?,
        activityRunEpoch: UInt64
    ) async {
        _ = activityRunEpoch
        await poll(id, trigger: trigger, manualCycle: manualCycle)
    }
}

@MainActor public protocol ProcessActivityLeasing: AnyObject {
    var isHeld: Bool { get }
    /// Takes the lease, claiming only as much of the machine as the work in hand deserves.
    ///
    /// `isUserInitiated` is the whole of the difference between "somebody is waiting for this,
    /// do not nap" and "this is maintenance, schedule it however suits you". It is not a hint.
    func begin(reason: StaticString, isUserInitiated: Bool)
    func end()
}

@MainActor protocol NetworkPathMonitoring: AnyObject {
    var statusUpdates: AsyncStream<Bool> { get }
    func start()
    func cancel()
}

nonisolated enum SupervisorRetirementReason: Equatable, Sendable {
    case replaced
    case removed
    case suspended
    case lineageReset
    case stopped
    case displayDark
}

nonisolated enum PollingLifecycleEvent: Equatable, Sendable {
    case pumpCreated
    case pumpRetired
    case supervisorCreated(
        accountID: AccountID,
        runID: UInt64,
        trigger: PollTrigger,
        attentionEpoch: UInt64?
    )
    case supervisorRetired(
        accountID: AccountID,
        runID: UInt64,
        reason: SupervisorRetirementReason
    )
    case supervisorExited(accountID: AccountID, runID: UInt64)
}

@MainActor protocol PollingLifecycleReporting: AnyObject {
    func record(_ event: PollingLifecycleEvent)
}

@MainActor
public final class ProductionUsagePollingSystem {
    public let store: AccountsStore

    public init(
        clock: any PollClock,
        vault: any TokenVault,
        providers: [AccountProvider: any ProductionUsageProvider],
        activityLease: any ProcessActivityLeasing
    ) {
        let engine = UsagePollingEngine(clock: clock, vault: vault, providers: providers)
        self.store = AccountsStore(
            clock: clock,
            engine: engine,
            activityLease: activityLease,
            lifecycle: nil,
            // This is the app's only production store, so this is the one line that decides
            // whether QotaFolio remembers anything between launches.
            history: UsageHistory.live()
        )
    }

    init(store: AccountsStore) {
        self.store = store
    }

    /// Stops polling and returns when the stop has been carried out. It always returns: the
    /// stop cancels, it does not wait for a cancelled request to admit that it was cancelled.
    public func stopAndDrain() async {
        await store.beginStop().wait()
    }

    /// Writes the buffered usage samples before the process leaves. Call after `stopAndDrain()`,
    /// so nothing is still arriving, and inside the quit's own budget — a slow disk must delay
    /// a quit no more than anything else does.
    public func flushHistory() async {
        await store.flushHistory()
    }
}
