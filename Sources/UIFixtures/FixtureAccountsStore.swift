import Foundation
import Observation
import QotaFolioCore

@MainActor @Observable public final class FixtureAccountsStore: AccountsStoring {
    public private(set) var snapshots: [AccountID: UsageSnapshot]
    public private(set) var pollStatus: [AccountID: AccountPollStatus]
    public private(set) var isPanelVisible: Bool
    public private(set) var manualRefresh: ManualRefreshActivity?
    public private(set) var usageUpdates: UsageUpdatesState
    /// What the fixture says about the fleet. `nil` by default — the state the app is in before
    /// its first poll — and whatever a scenario publishes through `publish(_:)`, which is how a
    /// fixture panel gets an instrument to open.
    public private(set) var assessment: FleetAssessment?
    /// The traces a fixture answers `trace(for:)` from, when a scenario replays a week into one.
    @ObservationIgnored public var traceBook: UsageTraceBook?

    @ObservationIgnored public private(set) var isRunning = false
    @ObservationIgnored public private(set) var refreshAllCallCount = 0
    @ObservationIgnored public private(set) var refreshRequests: [AccountID] = []
    @ObservationIgnored private var refreshID: UInt64 = 0

    public init(
        snapshots: [AccountID: UsageSnapshot] = [:],
        pollStatus: [AccountID: AccountPollStatus] = [:],
        isPanelVisible: Bool = false,
        manualRefresh: ManualRefreshActivity? = nil,
        usageUpdates: UsageUpdatesState = .running
    ) {
        self.snapshots = snapshots
        self.pollStatus = pollStatus
        self.isPanelVisible = isPanelVisible
        self.manualRefresh = manualRefresh
        self.usageUpdates = usageUpdates
    }

    public func start() {
        isRunning = true
    }

    public func stop() {
        isRunning = false
        manualRefresh = nil
    }

    public func reconcile(
        accounts: [AccountConfig],
        reauthenticated: [AccountID: CredentialRevision]
    ) {
        let liveIDs = Set(accounts.map(\.id))
        snapshots = snapshots.filter { liveIDs.contains($0.key) }
        pollStatus = pollStatus.filter { liveIDs.contains($0.key) }
        for id in reauthenticated.keys {
            snapshots[id] = nil
        }
    }

    public func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
    }

    public func requestRefreshAll() {
        guard manualRefresh == nil else { return }
        refreshAllCallCount += 1
        refreshID &+= 1
        manualRefresh = .inProgress(id: refreshID, total: pollStatus.count)
    }

    public func requestRefresh(_ id: AccountID) {
        refreshRequests.append(id)
    }

    /// Publishes an assessment the way the production store does when the brain answers.
    public func publish(_ assessment: FleetAssessment?) {
        self.assessment = assessment
    }

    public func trace(for account: AccountID) async -> AccountUsageTrace? {
        traceBook?.trace(for: account)
    }
}
