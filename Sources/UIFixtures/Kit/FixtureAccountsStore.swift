import Foundation
import Observation
import QotaFolioCore
import QotaFolioKit

@MainActor @Observable public final class FixtureAccountsStore: AccountsStoring {
    public private(set) var snapshots: [AccountID: UsageSnapshot]
    public private(set) var pollStatus: [AccountID: AccountPollStatus]
    public private(set) var isPanelVisible: Bool
    public private(set) var manualRefresh: ManualRefreshActivity?
    public private(set) var usageUpdates: UsageUpdatesState
    /// Each account's readings, read from the fixture's books by the reader the app's history
    /// uses. Empty until `replay(_:)`.
    public private(set) var readings: AccountReadings = [:]
    /// The books the readings are read from: a scenario's replayed week, or its snapshots alone.
    @ObservationIgnored private var traces = UsageTraceBook()
    @ObservationIgnored private var books = UsageSnapshotBook()

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

    /// Takes a scenario's books, or with none its snapshots alone, and publishes the readings the
    /// app's history would read from them.
    public func replay(traces: UsageTraceBook?, snapshots replayed: UsageSnapshotBook?) {
        if let traces, let replayed {
            (self.traces, books) = (traces, replayed)
        } else {
            books = UsageSnapshotBook()
            for (id, snapshot) in snapshots { books.record(PersistedUsageSnapshot(account: id, snapshot: snapshot)) }
        }
        readings = AccountReadings(traces: self.traces, snapshots: books)
    }

    /// One poll arriving, as the app's history records it: into the books, then the readings and
    /// the snapshot published.
    public func record(_ snapshot: UsageSnapshot, for id: AccountID) {
        books.record(PersistedUsageSnapshot(account: id, snapshot: snapshot))
        traces.observe(snapshot, for: id)
        snapshots[id] = snapshot
        readings = AccountReadings(traces: traces, snapshots: books)
    }
}
