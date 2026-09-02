import Foundation
import Observation
import QotaFolioCore

nonisolated struct PendingAttention: Equatable, Sendable {
    let epoch: UInt64
    let trigger: PollTrigger
}

nonisolated struct PollingSystemConditions: Equatable, Sendable {
    let isLowPowerModeEnabled: Bool
    let thermalPressure: ThermalPressure

    @MainActor static func current() -> PollingSystemConditions {
        PollingSystemConditions(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalPressure: AccountsStore.pressure(for: ProcessInfo.processInfo.thermalState)
        )
    }
}

/// Whether any display can currently show the status strip.
///
/// The strip is the product, so a closed panel is not "invisible" — the number still has to be
/// right when the user glances up. Asleep screens and a locked session are different: nobody can
/// glance at anything, and every poll, presentation rebuild, and status-item image swap in that
/// state is spent on a screen that shows none of it.
nonisolated struct DisplayVisibility: Equatable, Sendable {
    var areScreensAsleep: Bool
    var isSessionLocked: Bool

    var isVisible: Bool {
        !areScreensAsleep && !isSessionLocked
    }
}

/// What a caller of `stop()` waits on: the moment the pump has actually carried the stop out —
/// every supervisor cancelled, every flight cancelled, no new request possible.
///
/// It always arrives, and it deliberately does not wait for the cancelled work to finish dying.
/// A usage GET is an idempotent read; one that completes after the stop returns a number nobody
/// reads. Waiting for it would put a stalled TLS handshake between the user and a quit.
@MainActor final class StopDrain {
    private(set) var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isComplete else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func complete() {
        guard !isComplete else { return }
        isComplete = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private nonisolated enum StoreEngineOperation: Sendable {
    case attach
    case reprojectRateLimitWallDates(epoch: UInt64)
    case upsert(
        [AccountConfig],
        accountEpochs: [AccountID: UInt64],
        startWith: PollTrigger?,
        epoch: UInt64?
    )
    case suspend(AccountID, accountEpoch: UInt64)
    case resetLineage(AccountID, CredentialRevision, accountEpoch: UInt64, epoch: UInt64?)
    case remove(AccountID, accountEpoch: UInt64)
    case stopAll(drain: StopDrain)
}

@MainActor private struct SupervisorHandle {
    let runID: UInt64
    let task: Task<Void, Never>
}

@MainActor @Observable public final class AccountsStore: AccountsStoring, PollReporting {
    public private(set) var snapshots: [AccountID: UsageSnapshot] = [:]
    public private(set) var pollStatus: [AccountID: AccountPollStatus] = [:]
    public private(set) var isPanelVisible = false
    public private(set) var manualRefresh: ManualRefreshActivity?

    /// What the app has decided about the fleet: which account to use, and when that answer
    /// could change on its own.
    ///
    /// `nil` until the app has read its own books once, and that is a real state rather than
    /// a placeholder — before there is an assessment the strip draws every battery at full
    /// strength, because nothing has been chosen and nobody should be shown sitting back.
    public private(set) var assessment: FleetAssessment?

    /// Whether quota updates are still running for this run of the app.
    ///
    /// Nothing can stop them. The engine cancels, clears and carries on; there is no state in
    /// which the app is alive and its numbers are permanently frozen, so this answers `.running`
    /// for the life of the process.
    public var usageUpdates: UsageUpdatesState { .running }

    @ObservationIgnored private let engine: any UsagePollingEngineDriving
    @ObservationIgnored private let activityLease: any ProcessActivityLeasing
    @ObservationIgnored private let lifecycle: (any PollingLifecycleReporting)?
    @ObservationIgnored private let systemConditions: @MainActor () -> PollingSystemConditions

    /// One monotonic sequence behind every "is this still the message I asked for?" stamp in the
    /// store: the run, each account mutation, each attention trigger, each supervisor. They are
    /// different questions with different lifetimes, so they keep their own latches — but they
    /// draw from one well, so there is one place to bump and none to forget.
    @ObservationIgnored private var epochCounter: UInt64 = 0
    @ObservationIgnored private(set) var activeEpoch: UInt64?
    @ObservationIgnored private var accountEpoch: [AccountID: UInt64] = [:]

    @ObservationIgnored private var supervisors: [AccountID: SupervisorHandle] = [:]
    /// Which epoch of each account the engine has finished being told about.
    ///
    /// Equal to `accountEpoch[id]` means the engine holds the account as the store now
    /// understands it: established, not mid-suspension, not mid-reconnect. That one comparison
    /// is what starts a supervisor, and it is the whole of "is this still the account I asked
    /// about?".
    @ObservationIgnored private var engineEpoch: [AccountID: UInt64] = [:]
    @ObservationIgnored private var lastReport: [AccountID: PollReport] = [:]
    @ObservationIgnored private var pendingNextAttemptDeadline: [AccountID: PollInstant] = [:]
    @ObservationIgnored private var lastPanelOpenAt: PollInstant?
    @ObservationIgnored private var pendingAttention: [AccountID: PendingAttention] = [:]
    @ObservationIgnored private let ops: AsyncStream<StoreEngineOperation>.Continuation
    @ObservationIgnored private var pump: Task<Void, Never>?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private var stopDrain: StopDrain?

    @ObservationIgnored var isSystemSleeping = false
    @ObservationIgnored private var activePollingActivities: Set<PollingActivityIdentity> = []
    @ObservationIgnored private var manualCycleCounter: UInt64 = 0
    @ObservationIgnored private var manualPending: Set<AccountID> = []
    /// Accounts whose manual refresh arrived before the engine had been told about them. One set,
    /// filled when a refresh cannot start and drained the moment the engine catches up.
    @ObservationIgnored private var deferredManualAccounts: Set<AccountID> = []
    @ObservationIgnored private var manualLinger: Task<Void, Never>?
    /// Wakes at the assessment's own `nextReviewAt` — the earliest reset or verdict boundary
    /// — and asks again. The answer changes when a window resets whether or not anyone polled,
    /// so the assessment carries its own next question and this is what asks it.
    @ObservationIgnored private var reviewWake: Task<Void, Never>?

    @ObservationIgnored let clock: any PollClock
    @ObservationIgnored var knownConfigs: [AccountID: AccountConfig] = [:]
    @ObservationIgnored var observerTasks: [Task<Void, Never>] = []
    @ObservationIgnored var pathMonitor: (any NetworkPathMonitoring)?
    @ObservationIgnored var pendingWake: Task<Void, Never>?
    @ObservationIgnored var isLowPowerModeEnabled: Bool
    @ObservationIgnored var thermalPressure: ThermalPressure
    @ObservationIgnored var pathSatisfied: Bool?
    @ObservationIgnored var displayVisibility = DisplayVisibility(
        areScreensAsleep: false,
        isSessionLocked: false
    )
    @ObservationIgnored let pathMonitorFactory: @MainActor () -> any NetworkPathMonitoring
    @ObservationIgnored let displayVisibilityProbe: @MainActor () -> DisplayVisibility

    /// What the app remembers between launches. Absent in tests, which own their own state and
    /// should never touch the container.
    ///
    /// Every call on it is synchronous, returns instantly, and cannot fail — the store never
    /// waits on a history write and never learns whether one succeeded. That is the point: a
    /// number the user is looking at must not be behind a disk.
    @ObservationIgnored let history: UsageHistory?

    public convenience init(
        clock: any PollClock,
        vault: any TokenVault,
        providers: [AccountProvider: any ProductionUsageProvider],
        activityLease: any ProcessActivityLeasing
    ) {
        self.init(
            clock: clock,
            engine: UsagePollingEngine(clock: clock, vault: vault, providers: providers),
            activityLease: activityLease,
            lifecycle: nil,
            pathMonitorFactory: { SystemNetworkPathMonitor() },
            systemConditions: { PollingSystemConditions.current() },
            history: UsageHistory.live()
        )
    }

    internal init(
        clock: any PollClock,
        engine: any UsagePollingEngineDriving,
        activityLease: any ProcessActivityLeasing,
        lifecycle: (any PollingLifecycleReporting)?,
        pathMonitorFactory: @escaping @MainActor () -> any NetworkPathMonitoring = {
            SystemNetworkPathMonitor()
        },
        systemConditions: @escaping @MainActor () -> PollingSystemConditions = {
            PollingSystemConditions.current()
        },
        displayVisibilityProbe: @escaping @MainActor () -> DisplayVisibility = {
            DisplayVisibility.current()
        },
        // No default, deliberately. An optional dependency with a quiet default is a feature
        // that can be absent and never announce it — `ProductionUsagePollingSystem` builds the
        // store through this initialiser. Every caller says which it wants.
        history: UsageHistory?
    ) {
        self.clock = clock
        self.engine = engine
        self.activityLease = activityLease
        self.lifecycle = lifecycle
        self.history = history
        let initialConditions = systemConditions()
        self.isLowPowerModeEnabled = initialConditions.isLowPowerModeEnabled
        self.thermalPressure = initialConditions.thermalPressure
        self.pathMonitorFactory = pathMonitorFactory
        self.systemConditions = systemConditions
        self.displayVisibilityProbe = displayVisibilityProbe

        let (stream, continuation) = AsyncStream<StoreEngineOperation>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.ops = continuation

        history?.onAssessment = { [weak self] assessment in
            self?.publish(assessment)
        }

        let lifecycleSink = lifecycle
        self.pump = Task { @MainActor [weak self, lifecycleSink] in
            defer { lifecycleSink?.record(.pumpRetired) }
            for await operation in stream {
                guard let self else { return }
                await self.apply(operation)
            }
        }
        lifecycleSink?.record(.pumpCreated)
        continuation.yield(.attach)
    }

    deinit {
        ops.finish()
    }

    // MARK: - Run lifecycle

    public func start() {
        guard !isRunning else { return }
        stopDrain = nil
        let epoch = mintEpoch()
        activeEpoch = epoch
        isRunning = true
        isSystemSleeping = false
        // Ask, rather than assume the screens are awake. A background updater can relaunch this
        // agent at three in the morning, and no screen-sleep notification will ever arrive for a
        // screen that was already asleep when the process started.
        displayVisibility = displayVisibilityProbe()
        refreshSystemConditions()

        // The panel is about to be openable, and the first fetch is seconds away at best. Show
        // what we last saw rather than an empty card — each snapshot carries its own age, so a
        // stale number is offered as a stale number and never as news.
        //
        // Only on a cold start. A stop/start cycle already holds newer numbers in memory than
        // the file does, and re-reading would walk the display backwards.
        if snapshots.isEmpty, let restored = history?.restoreSnapshots(), !restored.isEmpty {
            snapshots = restored
        }

        let configs = stableConfigs()
        ops.yield(
            .upsert(
                configs,
                accountEpochs: operationEpochs(for: configs),
                startWith: .accountAdded,
                epoch: epoch
            )
        )
        installObservers(runEpoch: epoch)
        updateActivityLease()
    }

    public func stop() {
        _ = beginStop()
    }

    /// Ends the run and hands back the thing to wait on. Idempotent within a run: a second call
    /// returns the same drain rather than issuing a second stop.
    @discardableResult
    func beginStop() -> StopDrain {
        if let stopDrain {
            return stopDrain
        }

        let drain = StopDrain()
        stopDrain = drain
        isRunning = false
        activeEpoch = nil

        retireAllSupervisors(reason: .stopped)
        reviewWake?.cancel()
        reviewWake = nil
        pendingAttention.removeAll()
        pendingNextAttemptDeadline.removeAll()
        tearDownObservers()

        abandonManualCycle()

        ops.yield(.stopAll(drain: drain))
        updateActivityLease()
        return drain
    }

    // MARK: - Account set

    public func reconcile(
        accounts: [AccountConfig],
        reauthenticated: [AccountID: CredentialRevision]
    ) {
        let incoming = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        precondition(incoming.count == accounts.count, "duplicate account IDs in polling reconcile")
        let epoch = activeEpoch

        let removed = Set(knownConfigs.keys).subtracting(incoming.keys)
        for id in stableIDs(removed) {
            let operationEpoch = mintAccountEpoch(for: id)
            retireSupervisor(id, reason: .removed)
            pendingAttention[id] = nil
            pendingNextAttemptDeadline[id] = nil
            snapshots[id] = nil
            // The fleet as it will be, not as it was: this loop runs before `knownConfigs` is
            // replaced, and an assessment naming the account it just forgot is a lie about
            // the fleet a tenth of a second before anyone could read it.
            history?.forget(id, fleet: fleetAccounts(incoming.values))
            pollStatus[id] = nil
            lastReport[id] = nil
            engineEpoch[id] = nil
            deferredManualAccounts.remove(id)
            ops.yield(.remove(id, accountEpoch: operationEpoch))
        }

        for account in accounts {
            guard let previous = knownConfigs[account.id] else {
                let operationEpoch = mintAccountEpoch(for: account.id)
                ops.yield(
                    .upsert(
                        [account],
                        accountEpochs: [account.id: operationEpoch],
                        startWith: isRunning ? .accountAdded : nil,
                        epoch: epoch
                    )
                )
                continue
            }

            precondition(
                previous.provider == account.provider,
                "provider changes require remove and add with a fresh account ID"
            )

            if let revision = reauthenticated[account.id] {
                let operationEpoch = mintAccountEpoch(for: account.id)
                // The old grant's number goes here, at the instant the epoch is minted, not
                // when the engine gets round to saying so. This is the whole of "a Reconnect
                // never shows the old grant's number": there is no window in which the panel
                // still holds it, and no queue of pending resets to keep in step.
                //
                // History leaves with it. The row now points at a different grant, and
                // splicing two accounts' usage into one line would read as a burn rate that
                // nobody could see was wrong.
                snapshots[account.id] = nil
                history?.forget(account.id, fleet: fleetAccounts(incoming.values))
                retireSupervisor(account.id, reason: .lineageReset)
                pendingAttention[account.id] = nil
                ops.yield(
                    .resetLineage(
                        account.id,
                        revision,
                        accountEpoch: operationEpoch,
                        epoch: epoch
                    )
                )
                continue
            }

            if case .connected = previous.authorizationState,
               case .needsReauthentication = account.authorizationState
            {
                let operationEpoch = mintAccountEpoch(for: account.id)
                deferredManualAccounts.remove(account.id)
                retireSupervisor(account.id, reason: .suspended)
                pendingAttention[account.id] = nil
                ops.yield(.suspend(account.id, accountEpoch: operationEpoch))
            }
        }

        knownConfigs = incoming
        completeManualCycleIfReady()
        updateActivityLease()
        // A rename, a reorder, an account added or signed out: the fleet changed without a
        // poll, so the answer is asked again. It costs a pass over books already in memory.
        reassess()
    }

    // MARK: - Triggers

    public func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        if visible {
            lastPanelOpenAt = clock.now()
        }
        guard let epoch = activeEpoch else { return }
        startSupervisors(
            stableIDs(knownConfigs.keys),
            trigger: visible ? .panelOpened : .contextChanged,
            runEpoch: epoch
        )
    }

    public func requestRefreshAll() {
        guard isRunning, let epoch = activeEpoch else { return }
        if case .inProgress = manualRefresh { return }

        manualLinger?.cancel()
        manualLinger = nil
        manualRefresh = nil

        precondition(manualCycleCounter != .max, "manual refresh cycle ID exhausted")
        manualCycleCounter += 1
        let cycle = manualCycleCounter
        let participants = Set(knownConfigs.keys.filter(isAccountPollable))

        manualPending = participants
        manualRefresh = .inProgress(id: cycle, total: participants.count)

        guard !participants.isEmpty else {
            completeManualCycle(cycle)
            return
        }

        let ready = participants.filter(isEstablishedInEngine)
        deferredManualAccounts.formUnion(participants.subtracting(ready))
        startSupervisors(stableIDs(ready), trigger: .manual, runEpoch: epoch)
    }

    public func requestRefresh(_ id: AccountID) {
        guard isRunning, let epoch = activeEpoch, isAccountPollable(id) else { return }
        guard isEstablishedInEngine(id) else {
            deferredManualAccounts.insert(id)
            return
        }
        startSupervisors([id], trigger: .manual, runEpoch: epoch)
    }

    func reprojectRateLimitWallDates() {
        guard let epoch = activeEpoch, isActiveRun(epoch) else { return }
        ops.yield(.reprojectRateLimitWallDates(epoch: epoch))
    }

    // MARK: - Engine reports

    /// One question, asked once: is this still the account I asked about?
    ///
    /// A flight from a grant the user has replaced, a suspension answered after a Remove, a
    /// report about a row that no longer exists — every one of them fails this comparison,
    /// because every operation that changes what an account *is* mints a new epoch before the
    /// engine is told.
    func receive(_ report: PollReport) {
        let id = report.accountID
        guard knownConfigs[id] != nil, accountEpoch[id] == report.epoch else { return }
        applyAcceptedReport(report)
    }

    func manualParticipantSettled(_ id: AccountID, cycle: UInt64) {
        guard cycle == manualCycleCounter else { return }
        guard manualPending.remove(id) != nil else { return }
        deferredManualAccounts.remove(id)
        completeManualCycleIfReady()
    }

    func pollingActivityDidBegin(_ activity: PollingActivityIdentity) {
        guard isActiveRun(activity.runEpoch) else { return }
        activePollingActivities.insert(activity)
        updateActivityLease()
    }

    func pollingActivityDidEnd(_ activity: PollingActivityIdentity) {
        activePollingActivities.remove(activity)
        updateActivityLease()
    }

    private func applyAcceptedReport(_ report: PollReport) {
        let id = report.accountID
        lastReport[id] = report

        switch report.snapshot {
        case .unchanged:
            break
        case .replaced(let snapshot):
            adoptSnapshot(snapshot, for: id)
        case .cleared:
            snapshots[id] = nil
            // History leaves with the lineage. A cleared snapshot means this row now points at a
            // different grant, and the app itself has stopped trusting its old numbers. Carrying
            // a trace across that would let two accounts' usage be spliced into one line, and
            // the brain would read the join as a burn rate — wrong in a way nobody could see.
            //
            // The cost is a day of samples after a reconnect. The alternative is a confident
            // wrong recommendation, which is the one thing this app must not produce.
            history?.forget(id, fleet: fleetAccounts())
        }

        let pollable = PollingPolicy.isPollable(report.phase)
        if !pollable {
            pendingNextAttemptDeadline[id] = nil
        }
        publishStatus(for: id)
        updateActivityLease()
        if !pollable {
            settleManualParticipant(id)
        }
    }

    /// Asks the brain again over the books as they stand, without waiting for a poll.
    ///
    /// Public because more than one thing has reason to ask: the review wake below, and any
    /// surface that has just been shown and wants the freshest answer before it draws.
    public func reassess() {
        history?.reassess(fleet: fleetAccounts())
    }

    public func trace(for account: AccountID) async -> AccountUsageTrace? {
        await history?.trace(for: account)
    }

    /// The catalog rows the brain is given, in the user's own order.
    ///
    /// Built here, on the main actor, and carried into the writer by value, so that nothing
    /// off the main actor ever reaches for `AccountCatalog`.
    private func fleetAccounts() -> [FleetAccount] {
        fleetAccounts(knownConfigs.values)
    }

    private func fleetAccounts(_ configs: some Collection<AccountConfig>) -> [FleetAccount] {
        configs
            .sorted { lhs, rhs in
                lhs.displayOrder == rhs.displayOrder
                    ? lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
                    : lhs.displayOrder < rhs.displayOrder
            }
            .map(FleetAccount.init(config:))
    }

    private func publish(_ assessment: FleetAssessment) {
        self.assessment = assessment
        reconcileReviewWake(assessment.nextReviewAt)
    }

    /// Arms one timer at the assessment's own next question, and no timer at all when it has
    /// none. Re-arming for an instant already reached would spin, so a deadline in the past
    /// asks again once rather than scheduling.
    private func reconcileReviewWake(_ deadline: Date?) {
        reviewWake?.cancel()
        reviewWake = nil
        guard let deadline else { return }

        let interval = deadline.timeIntervalSince(clock.wallNow())
        guard interval > 0 else { return }
        reviewWake = Task { @MainActor [weak self] in
            try? await Task.sleep(
                // Floored at a second. An assessment is entitled to name any instant it
                // likes, and one that keeps naming an instant a millisecond away would
                // otherwise be a timer spinning on a laptop battery for the rest of the day.
                // A verdict boundary is never that urgent.
                for: .seconds(max(interval, 1)),
                // Half a minute of drift on a verdict boundary is invisible, and it lets macOS
                // fold this wake into work it was already doing.
                tolerance: .seconds(30)
            )
            guard let self, !Task.isCancelled else { return }
            self.reviewWake = nil
            self.reassess()
        }
    }

    /// Writes the samples still buffered in memory, and returns when they are on disk.
    ///
    /// For a graceful quit only. History batches behind a five-minute deadline so that a poll
    /// never waits on a disk; without this call every ordinary quit discards up to five minutes
    /// of the samples the app spent the day collecting, which is not what
    /// `UsageHistoryPolicy` promises. Never call it on a hot path.
    public func flushHistory() async {
        await history?.flush()
    }

    /// The one place a fresh usage reading enters the store.
    ///
    /// Every successful poll arrives here, including one that repeats the last numbers exactly,
    /// because an unchanged reading is still a measurement. Only the *published* value is
    /// deduplicated, and only to spare the panel a redraw it does not need.
    private func adoptSnapshot(_ snapshot: UsageSnapshot, for id: AccountID) {
        // Recorded above the guard on purpose: the sample ring wants every measurement, and a
        // window that has not moved for an hour is a fact the verdict engine needs.
        history?.record(snapshot, for: id, fleet: fleetAccounts())

        guard snapshots[id] != snapshot else { return }
        snapshots[id] = snapshot
    }

    // MARK: - The pump

    private func apply(_ operation: StoreEngineOperation) async {
        switch operation {
        case .attach:
            await engine.attach(self)

        case .reprojectRateLimitWallDates(let epoch):
            guard isActiveRun(epoch) else { return }
            await engine.reprojectRateLimitWallDates()

        case .upsert(let configs, let epochs, let trigger, let epoch):
            // Upsert is a prerequisite, not a terminal mutation. A later reset or suspend may
            // supersede its supervisor start, but it must not erase the only operation that
            // establishes engine state.
            let current = configs.filter { knownConfigs[$0.id] != nil }
            guard !current.isEmpty else { return }

            await engine.upsert(current, epochs: epochs)
            for account in current where knownConfigs[account.id] != nil {
                markEstablished(account.id, at: epochs[account.id])
            }

            guard let trigger, let epoch, isActiveRun(epoch) else { return }
            let startable = current.map(\.id).filter { accountEpoch[$0] == epochs[$0] }
            admitSupervisors(startable, defaultTrigger: trigger, runEpoch: epoch)

        case .suspend(let id, let operationEpoch):
            guard accountEpoch[id] == operationEpoch else { return }
            await engine.suspend(id, epoch: operationEpoch)
            markEstablished(id, at: operationEpoch)

        case .resetLineage(let id, let revision, let operationEpoch, let epoch):
            guard accountEpoch[id] == operationEpoch else { return }
            await engine.resetLineage(id, revision: revision, epoch: operationEpoch)
            // A second Reconnect while this one was in the pump minted a newer epoch, and this
            // operation no longer speaks for the account. Nothing to unwind: the engine holds
            // the older epoch, every report it makes is stamped with it, and `receive` refuses
            // them until the newer reset lands.
            guard accountEpoch[id] == operationEpoch else { return }
            markEstablished(id, at: operationEpoch)
            updateActivityLease()
            guard let epoch, isActiveRun(epoch) else { return }
            admitSupervisors([id], defaultTrigger: .accountAdded, runEpoch: epoch)

        case .remove(let id, let operationEpoch):
            guard accountEpoch[id] == operationEpoch, knownConfigs[id] == nil else { return }
            await engine.remove(id)
            engineEpoch[id] = nil
            accountEpoch[id] = nil
            settleManualParticipant(id)

        case .stopAll(let drain):
            await engine.stopAll()
            drain.complete()
            updateActivityLease()
        }
    }

    // MARK: - Supervisors

    func startSupervisors(
        _ ids: [AccountID],
        trigger: PollTrigger,
        runEpoch: UInt64
    ) {
        guard isActiveRun(runEpoch) else { return }
        // The one gate. Every supervisor in this app is born here, so this single guard is what
        // keeps a dark machine silent — including for the thermal, power, and calendar-day events
        // that keep arriving while the screens are asleep. `handleScreensDidWake` and
        // `handleSessionDidUnlock` restart them with an attention trigger, so the catch-up poll is
        // part of coming back rather than a separate mechanism.
        guard displayVisibility.isVisible else { return }

        for id in stableIDs(ids) {
            guard isEstablishedInEngine(id), isAccountPollable(id) else { continue }

            let attention: PendingAttention?
            if PollingPolicy.isAttention(trigger) {
                let newest = PendingAttention(epoch: mintEpoch(), trigger: trigger)
                pendingAttention[id] = newest
                attention = newest
            } else {
                attention = pendingAttention[id]
            }
            let effectiveTrigger = attention?.trigger ?? trigger

            retireSupervisor(id, reason: .replaced)
            let runID = mintEpoch()
            let task = supervisorTask(
                id,
                consuming: attention,
                runID: runID,
                runEpoch: runEpoch
            )
            supervisors[id] = SupervisorHandle(runID: runID, task: task)
            lifecycle?.record(
                .supervisorCreated(
                    accountID: id,
                    runID: runID,
                    trigger: effectiveTrigger,
                    attentionEpoch: attention?.epoch
                )
            )
        }
    }

    /// Starts supervisors once the engine knows about the accounts, giving any manual refresh
    /// that arrived early its manual trigger rather than the operation's default.
    private func admitSupervisors(
        _ defaultIDs: [AccountID],
        defaultTrigger: PollTrigger,
        runEpoch: UInt64
    ) {
        guard isActiveRun(runEpoch) else { return }

        let manualIDs = deferredManualAccounts.filter {
            isEstablishedInEngine($0) && isAccountPollable($0)
        }
        deferredManualAccounts.subtract(manualIDs)

        startSupervisors(
            defaultIDs.filter { !manualIDs.contains($0) },
            trigger: defaultTrigger,
            runEpoch: runEpoch
        )
        startSupervisors(stableIDs(manualIDs), trigger: .manual, runEpoch: runEpoch)
    }

    func isActiveRun(_ epoch: UInt64) -> Bool {
        isRunning && activeEpoch == epoch
    }

    /// Retires every live supervisor without ending the run. An in-flight request keeps its own
    /// cancellation path, and the App Nap lease keeps following that work, not this call.
    func retireAllSupervisors(reason: SupervisorRetirementReason) {
        for id in stableIDs(supervisors.keys) {
            retireSupervisor(id, reason: reason)
        }
    }

    private func supervisorTask(
        _ id: AccountID,
        consuming attention: PendingAttention?,
        runID: UInt64,
        runEpoch: UInt64
    ) -> Task<Void, Never> {
        let lifecycleSink = lifecycle
        return Task { @MainActor [weak self, lifecycleSink] in
            defer {
                self?.supervisorDidExit(id: id, runID: runID)
                lifecycleSink?.record(.supervisorExited(accountID: id, runID: runID))
            }
            var attentionToConsume = attention

            while let self, !Task.isCancelled, self.isActiveRun(runEpoch) {
                if let captured = attentionToConsume {
                    precondition(PollingPolicy.isAttention(captured.trigger))
                    await self.engine.poll(
                        id,
                        trigger: captured.trigger,
                        manualCycle: self.activeCycleID(covering: id),
                        activityRunEpoch: runEpoch
                    )
                    guard !Task.isCancelled, self.isActiveRun(runEpoch) else { return }
                    if self.pendingAttention[id]?.epoch == captured.epoch {
                        self.pendingAttention[id] = nil
                    }
                    attentionToConsume = nil
                    guard self.isAccountPollable(id) else { return }
                }

                guard self.isActiveRun(runEpoch),
                      let input = self.makeCadenceInput(id)
                else { return }
                let decision = AdaptiveCadence.decide(input)
                let deadline = self.clock.adding(decision.delay, to: self.clock.now())
                self.setNextAttempt(id, deadline)

                do {
                    try await self.clock.sleep(
                        until: deadline,
                        tolerance: decision.tolerance
                    )
                } catch {
                    return
                }
                guard !Task.isCancelled, self.isActiveRun(runEpoch) else { return }

                await self.engine.poll(
                    id,
                    trigger: .scheduled,
                    manualCycle: self.activeCycleID(covering: id),
                    activityRunEpoch: runEpoch
                )
                guard !Task.isCancelled,
                      self.isActiveRun(runEpoch),
                      self.isAccountPollable(id)
                else { return }
            }
        }
    }

    private func retireSupervisor(_ id: AccountID, reason: SupervisorRetirementReason) {
        guard let handle = supervisors.removeValue(forKey: id) else { return }
        handle.task.cancel()
        lifecycle?.record(
            .supervisorRetired(accountID: id, runID: handle.runID, reason: reason)
        )
    }

    private func supervisorDidExit(id: AccountID, runID: UInt64) {
        if supervisors[id]?.runID == runID {
            supervisors[id] = nil
        }
    }

    // MARK: - Cadence

    private func makeCadenceInput(_ id: AccountID) -> CadenceInput? {
        guard let config = knownConfigs[id] else { return nil }
        let report = lastReport[id]
        let now = clock.now()
        let floorRemaining = report?.lastRequestStartedAt.map {
            max(.zero, PollingPolicy.hardFloor - clock.duration(from: $0, to: now))
        } ?? .zero
        let backoffRemaining = report?.backoffUntil.map {
            max(.zero, clock.duration(from: now, to: $0))
        } ?? .zero
        let resetDuration = earliestReset(id).flatMap(durationUntilReset)

        return CadenceInput(
            provider: config.provider,
            isPanelVisible: isPanelVisible,
            timeSinceLastPanelOpen: lastPanelOpenAt.map {
                clock.duration(from: $0, to: now)
            },
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            thermalPressure: thermalPressure,
            timeSinceLastRequestStart: report?.lastRequestStartedAt.map {
                clock.duration(from: $0, to: now)
            },
            cacheAge: report?.cachedAt.map {
                clock.duration(from: $0, to: now)
            },
            hardNotBefore: max(floorRemaining, backoffRemaining),
            consecutiveFailures: report?.consecutiveFailures ?? 0,
            timeUntilEarliestReset: resetDuration
        )
    }

    private func earliestReset(_ id: AccountID) -> Date? {
        guard let snapshot = snapshots[id] else { return nil }
        let now = clock.wallNow()
        // Every window the provider reported, not a fixed few: the next poll should be timed
        // to whichever quota comes back first, whichever window that turns out to be.
        return snapshot.readings
            .compactMap { $0.window.resetsAt }
            .filter { $0 > now }
            .min()
    }

    private func durationUntilReset(_ reset: Date) -> Duration? {
        let seconds = reset.timeIntervalSince(clock.wallNow())
        guard seconds.isFinite, seconds > 0 else { return nil }
        let maximumRelevant = PollingPolicy.cadenceCeiling.timeIntervalValue
        return .seconds(min(seconds, maximumRelevant))
    }

    private func setNextAttempt(_ id: AccountID, _ deadline: PollInstant) {
        pendingNextAttemptDeadline[id] = deadline
        publishStatus(for: id)
    }

    /// The one place the panel's per-account status is written, from the last report the engine
    /// sent and the deadline the cadence chose. An account with no next attempt shows none.
    private func publishStatus(for id: AccountID) {
        guard let report = lastReport[id] else { return }
        pollStatus[id] = AccountPollStatus(
            phase: report.phase,
            isRefreshing: report.isRefreshing,
            lastAttemptAt: report.lastAttemptAt,
            lastSuccessAt: report.lastSuccessAt,
            nextAttemptAt: PollingPolicy.isPollable(report.phase)
                ? pendingNextAttemptDeadline[id].map { clock.wallDate(for: $0) }
                : nil
        )
    }

    // MARK: - Manual refresh

    private func activeCycleID(covering id: AccountID) -> UInt64? {
        manualPending.contains(id) ? manualCycleCounter : nil
    }

    private func completeManualCycleIfReady() {
        guard manualPending.isEmpty else { return }
        guard case .inProgress(let cycle, _) = manualRefresh else { return }
        completeManualCycle(cycle, runEpoch: activeEpoch)
    }

    private func completeManualCycle(_ cycle: UInt64, runEpoch: UInt64? = nil) {
        guard cycle == manualCycleCounter else { return }
        if let runEpoch, !isActiveRun(runEpoch) { return }
        manualPending.removeAll()
        manualRefresh = .completed(id: cycle, at: clock.wallNow())
        armManualCompletionLinger(cycle, completionRunEpoch: activeEpoch)
    }

    private func armManualCompletionLinger(
        _ cycle: UInt64,
        completionRunEpoch: UInt64?
    ) {
        manualLinger?.cancel()
        let clock = clock
        manualLinger = Task { @MainActor [weak self] in
            let deadline = clock.adding(
                PollingPolicy.manualCompletionLinger,
                to: clock.now()
            )
            do {
                try await clock.sleep(until: deadline, tolerance: .seconds(1))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.activeEpoch == completionRunEpoch
            else { return }
            if case .completed(let publishedCycle, _) = self.manualRefresh,
               publishedCycle == cycle
            {
                self.manualRefresh = nil
                self.manualLinger = nil
            }
        }
    }

    private func settleManualParticipant(_ id: AccountID) {
        guard manualPending.remove(id) != nil else { return }
        deferredManualAccounts.remove(id)
        completeManualCycleIfReady()
    }

    /// Ends an unfinished manual refresh without claiming it finished.
    ///
    /// Two callers, one meaning: every supervisor carrying this cycle has been dropped and none
    /// of them will be replaced, so nothing is left that could ever settle it. `beginStop()` is
    /// one — the run is over. `setDisplayVisibility` is the other: retiring the supervisors as
    /// `.displayDark` starts no successors, and `startSupervisors` refuses to start any while the
    /// screens are dark, so without this call `manualPending` keeps the accounts, `manualRefresh`
    /// stays `.inProgress`, `requestRefreshAll()` returns at its first guard, and the spinner
    /// turns for as long as the screens sleep.
    ///
    /// Not `.completed`: a refresh that did not happen must not show a tick. Clearing it is the
    /// honest end, and it puts the button back. Nothing is lost by ending it — an unfinished
    /// manual refresh on a dark screen has no reader — and coming back is already an attention
    /// event that fetches a fresh number.
    ///
    /// The cycle counter is deliberately not bumped. A late acknowledgement from a supervisor
    /// that was already inside the engine still matches the counter, finds nothing in
    /// `manualPending`, and stops there.
    func abandonManualCycle() {
        manualLinger?.cancel()
        manualLinger = nil
        manualPending.removeAll()
        deferredManualAccounts.removeAll()
        manualRefresh = nil
    }

    // MARK: - Conditions and identity

    /// Whether the engine holds this account as the store now understands it.
    ///
    /// A supervisor is never born before this is true: not before the account exists inside
    /// the engine, not while a suspension is in the pump, and not while a Reconnect is. Three
    /// prerequisites, one comparison.
    private func isEstablishedInEngine(_ id: AccountID) -> Bool {
        guard let epoch = accountEpoch[id] else { return false }
        return engineEpoch[id] == epoch
    }

    private func markEstablished(_ id: AccountID, at epoch: UInt64?) {
        guard let epoch, accountEpoch[id] == epoch else { return }
        engineEpoch[id] = epoch
    }

    private func isAccountPollable(_ id: AccountID) -> Bool {
        guard let config = knownConfigs[id] else { return false }
        guard case .connected = config.authorizationState else { return false }
        return PollingPolicy.isPollable(
            pollStatus[id]?.phase ?? .waitingForFirstSnapshot
        )
    }

    func refreshSystemConditions() {
        let current = systemConditions()
        isLowPowerModeEnabled = current.isLowPowerModeEnabled
        thermalPressure = current.thermalPressure
    }

    private func mintEpoch() -> UInt64 {
        precondition(epochCounter != .max, "polling epoch exhausted")
        epochCounter += 1
        return epochCounter
    }

    private func mintAccountEpoch(for id: AccountID) -> UInt64 {
        let epoch = mintEpoch()
        accountEpoch[id] = epoch
        return epoch
    }

    private func operationEpochs(for configs: [AccountConfig]) -> [AccountID: UInt64] {
        Dictionary(uniqueKeysWithValues: configs.compactMap { config in
            accountEpoch[config.id].map { (config.id, $0) }
        })
    }

    private func stableConfigs() -> [AccountConfig] {
        stableIDs(knownConfigs.keys).compactMap { knownConfigs[$0] }
    }

    private func stableIDs<S: Sequence>(_ ids: S) -> [AccountID]
    where S.Element == AccountID {
        ids.sorted { lhs, rhs in
            lhs.rawValue.uuidString < rhs.rawValue.uuidString
        }
    }

    func updateActivityLease() {
        func isLive(_ activity: PollingActivityIdentity) -> Bool {
            activity.runEpoch == activeEpoch && isAccountPollable(activity.accountID)
        }
        let runningActivity = isRunning && activePollingActivities.contains(where: isLive)
        let shouldHold = !isSystemSleeping && pathSatisfied != false && runningActivity
        guard shouldHold else {
            activityLease.end()
            return
        }
        // One lease covers every flight in the air, so it carries the strongest claim any of
        // them has. One request the user is waiting for is enough to say the user is waiting.
        activityLease.begin(
            reason: "active usage request",
            isUserInitiated: activePollingActivities.contains {
                isLive($0) && PollingPolicy.isAttention($0.trigger)
            }
        )
    }

    static func pressure(
        for state: ProcessInfo.ThermalState
    ) -> ThermalPressure {
        switch state {
        case .nominal:
            .nominal
        case .fair:
            .fair
        case .serious:
            .serious
        case .critical:
            .critical
        @unknown default:
            .critical
        }
    }
}
