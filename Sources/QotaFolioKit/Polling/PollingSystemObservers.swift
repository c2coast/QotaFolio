import AppKit
import CoreGraphics
import Foundation
import Network
import QotaFolioCore

/// The names macOS posts when the session locks and unlocks. They carry no symbol and no
/// entitlement — they are ordinary distributed notifications, and they are the only signal the
/// system offers for a locked session that still has its screens lit.
nonisolated enum SessionLockNotification {
    static let locked = Notification.Name("com.apple.screenIsLocked")
    static let unlocked = Notification.Name("com.apple.screenIsUnlocked")
}

nonisolated extension DisplayVisibility {
    /// Seeds the run. Transitions come from the notifications; this answers the one question the
    /// notifications cannot — what was already true when the process started.
    @MainActor static func current() -> DisplayVisibility {
        DisplayVisibility(
            areScreensAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0,
            isSessionLocked: isSessionLocked()
        )
    }

    @MainActor private static func isSessionLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

@MainActor final class SystemNetworkPathMonitor: NetworkPathMonitoring {
    let statusUpdates: AsyncStream<Bool>

    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let continuation: AsyncStream<Bool>.Continuation
    private var started = false

    init() {
        let monitor = NWPathMonitor()
        let (updates, continuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.monitor = monitor
        self.queue = DispatchQueue(
            label: "net.c2coast.QotaFolio.polling.path",
            qos: .utility
        )
        self.statusUpdates = updates
        self.continuation = continuation

        monitor.pathUpdateHandler = { path in
            let satisfied = path.status == .satisfied
            switch continuation.yield(satisfied) {
            case .enqueued, .dropped, .terminated:
                break
            @unknown default:
                break
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.start(queue: queue)
    }

    func cancel() {
        guard started else {
            continuation.finish()
            return
        }
        started = false
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        continuation.finish()
    }

    deinit {
        continuation.finish()
        monitor.cancel()
    }
}

/// What the process tells macOS while a poll is in the air.
///
/// `NSActivityUserInitiatedAllowingIdleSystemSleep` says the user is waiting: it exempts the
/// process from App Nap and from timer throttling, and it also carries
/// `NSActivitySuddenTerminationDisabled` and `NSActivityAutomaticTerminationDisabled`. For the
/// poll behind an open panel or a pressed Refresh that is exactly true. Asserting it for every
/// flight — including a thirty-minute-tier refresh of a menu bar nobody is looking at — suppresses
/// precisely the App Nap that makes an agent like this cheap to run.
///
/// `NSActivityBackground` is what the system wants to hear from a menu-bar agent doing periodic
/// maintenance, and `PollingPolicy.isAttention(_:)` already draws the line between the two.
@MainActor public final class AppNapLease: ProcessActivityLeasing {
    private var token: NSObjectProtocol?

    public init() {}

    public var isHeld: Bool {
        token != nil
    }

    /// What the lease is currently claiming: `true` for the assertion that suppresses App Nap,
    /// `false` for the background one, `nil` while nothing is held. Readable because a control
    /// this cheap to get wrong should be able to say what it is doing.
    public private(set) var heldAsUserInitiated: Bool?

    public func begin(reason: StaticString, isUserInitiated: Bool) {
        // An attention poll starting behind a scheduled one upgrades the assertion rather than
        // being ignored: the lease is one token for the whole process, so the claim it carries
        // has to be the strongest claim any flight in the air has. The reverse is not an
        // upgrade — a scheduled poll joining an attention one changes nothing.
        let previous = token
        if previous != nil, !(isUserInitiated && heldAsUserInitiated != true) { return }

        // The new assertion is taken before the old one is released, so an upgrade never leaves
        // the process momentarily unasserted.
        token = ProcessInfo.processInfo.beginActivity(
            options: isUserInitiated ? .userInitiatedAllowingIdleSystemSleep : .background,
            reason: reason.description
        )
        heldAsUserInitiated = isUserInitiated
        if let previous {
            ProcessInfo.processInfo.endActivity(previous)
        }
    }

    public func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
        heldAsUserInitiated = nil
    }

    isolated deinit {
        if let token {
            ProcessInfo.processInfo.endActivity(token)
        }
    }
}

@MainActor extension AccountsStore {
    func installObservers(runEpoch: UInt64) {
        guard isActiveRun(runEpoch) else { return }
        guard observerTasks.isEmpty, pathMonitor == nil else {
            assertionFailure("polling observers installed twice")
            return
        }

        observerTasks.append(Task { @MainActor [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.willSleepNotification
            ) {
                guard !Task.isCancelled,
                      let self,
                      self.isActiveRun(runEpoch)
                else { return }
                self.handleSleep(runEpoch: runEpoch)
            }
        })

        observerTasks.append(Task { @MainActor [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.didWakeNotification
            ) {
                guard !Task.isCancelled,
                      let self,
                      self.isActiveRun(runEpoch)
                else { return }
                self.handleWake(runEpoch: runEpoch)
            }
        })

        observerTasks.append(Task { @MainActor [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.screensDidSleepNotification
            ) {
                guard !Task.isCancelled,
                      let self,
                      self.isActiveRun(runEpoch)
                else { return }
                self.handleScreensDidSleep(runEpoch: runEpoch)
            }
        })

        observerTasks.append(Task { @MainActor [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(
                named: NSWorkspace.screensDidWakeNotification
            ) {
                guard !Task.isCancelled,
                      let self,
                      self.isActiveRun(runEpoch)
                else { return }
                self.handleScreensDidWake(runEpoch: runEpoch)
            }
        })

        observerTasks.append(Task { @MainActor [weak self] in
            for await _ in DistributedNotificationCenter.default().notifications(
                named: SessionLockNotification.locked
            ) {
                guard !Task.isCancelled,
                      let self,
                      self.isActiveRun(runEpoch)
                else { return }
                self.handleSessionDidLock(runEpoch: runEpoch)
            }
        })

        observerTasks.append(Task { @MainActor [weak self] in
            for await _ in DistributedNotificationCenter.default().notifications(
                named: SessionLockNotification.unlocked
            ) {
                guard !Task.isCancelled,
                      let self,
                      self.isActiveRun(runEpoch)
                else { return }
                self.handleSessionDidUnlock(runEpoch: runEpoch)
            }
        })

        observerTasks.append(Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: ProcessInfo.thermalStateDidChangeNotification
            ) {
                guard !Task.isCancelled,
                      let self,
                      self.isActiveRun(runEpoch)
                else { return }
                self.handleThermalStateChange(runEpoch: runEpoch)
            }
        })

        observerTasks.append(Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .NSProcessInfoPowerStateDidChange
            ) {
                guard !Task.isCancelled,
                      let self,
                      self.isActiveRun(runEpoch)
                else { return }
                self.handlePowerStateChange(runEpoch: runEpoch)
            }
        })

        observerTasks.append(Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .NSSystemClockDidChange
            ) {
                guard !Task.isCancelled,
                      let self,
                      self.isActiveRun(runEpoch)
                else { return }
                self.handleSystemClockChange(runEpoch: runEpoch)
            }
        })

        observerTasks.append(Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: .NSCalendarDayChanged
            ) {
                guard !Task.isCancelled,
                      let self,
                      self.isActiveRun(runEpoch)
                else { return }
                self.handleCalendarDayChange(runEpoch: runEpoch)
            }
        })

        let monitor = pathMonitorFactory()
        pathMonitor = monitor
        observerTasks.append(Task { @MainActor [weak self, weak monitor] in
            guard let monitor else { return }
            for await satisfied in monitor.statusUpdates {
                guard !Task.isCancelled,
                      let self,
                      self.isActiveRun(runEpoch),
                      self.pathMonitor === monitor
                else { return }
                self.handleNetworkPath(satisfied: satisfied, runEpoch: runEpoch)
            }
        })
        monitor.start()
    }

    func tearDownObservers() {
        for task in observerTasks {
            task.cancel()
        }
        observerTasks.removeAll()
        pendingWake?.cancel()
        pendingWake = nil

        let monitor = pathMonitor
        pathMonitor = nil
        monitor?.cancel()
        pathSatisfied = nil
    }

    func handleSleep(runEpoch: UInt64) {
        guard isActiveRun(runEpoch) else { return }
        pendingWake?.cancel()
        pendingWake = nil
        isSystemSleeping = true
        updateActivityLease()
    }

    func handleWake(runEpoch: UInt64) {
        guard isActiveRun(runEpoch) else { return }
        isSystemSleeping = false
        updateActivityLease()
        scheduleAttention(.wake, runEpoch: runEpoch)
    }

    func handleScreensDidSleep(runEpoch: UInt64) {
        setDisplayVisibility(runEpoch: runEpoch) { $0.areScreensAsleep = true }
    }

    func handleScreensDidWake(runEpoch: UInt64) {
        setDisplayVisibility(runEpoch: runEpoch) { $0.areScreensAsleep = false }
    }

    func handleSessionDidLock(runEpoch: UInt64) {
        setDisplayVisibility(runEpoch: runEpoch) { $0.isSessionLocked = true }
    }

    func handleSessionDidUnlock(runEpoch: UInt64) {
        setDisplayVisibility(runEpoch: runEpoch) { $0.isSessionLocked = false }
    }

    /// Screens and session lock move independently — a screen wakes to a locked login window all
    /// the time — so both facts are tracked and the run gate reads their conjunction.
    private func setDisplayVisibility(
        runEpoch: UInt64,
        _ mutate: (inout DisplayVisibility) -> Void
    ) {
        guard isActiveRun(runEpoch) else { return }
        let wasVisible = displayVisibility.isVisible
        mutate(&displayVisibility)
        let isVisible = displayVisibility.isVisible
        guard wasVisible != isVisible else { return }

        guard isVisible else {
            pendingWake?.cancel()
            pendingWake = nil
            retireAllSupervisors(reason: .displayDark)
            // The one retirement that starts no successor, so the one that has to end the manual
            // cycle itself. Every other reason is settled by whatever follows it: `.replaced` by
            // the successor, `.removed` and `.suspended` by the pump and the report, `.stopped` by
            // `beginStop`, `.lineageReset` by the restart. Dark screens are followed by nothing
            // until they wake.
            abandonManualCycle()
            return
        }
        // Coming back is an attention event, and it takes the same path a system wake takes: one
        // coalesced catch-up round that publishes a refreshing state on its way to a fresh number.
        scheduleAttention(.wake, runEpoch: runEpoch)
    }

    func handleSystemClockChange(runEpoch: UInt64) {
        guard isActiveRun(runEpoch) else { return }
        reprojectRateLimitWallDates()
    }

    func handleCalendarDayChange(runEpoch: UInt64) {
        guard isActiveRun(runEpoch) else { return }
        startSupervisors(
            stableObserverIDs(),
            trigger: .contextChanged,
            runEpoch: runEpoch
        )
    }

    func handlePowerStateChange(runEpoch: UInt64) {
        guard isActiveRun(runEpoch) else { return }
        refreshSystemConditions()
        startSupervisors(
            stableObserverIDs(),
            trigger: .contextChanged,
            runEpoch: runEpoch
        )
    }

    func handleThermalStateChange(runEpoch: UInt64) {
        guard isActiveRun(runEpoch) else { return }
        refreshSystemConditions()
        startSupervisors(
            stableObserverIDs(),
            trigger: .contextChanged,
            runEpoch: runEpoch
        )
    }

    func handleNetworkPath(satisfied: Bool, runEpoch: UInt64) {
        guard isActiveRun(runEpoch) else { return }
        let previous = pathSatisfied
        pathSatisfied = satisfied
        updateActivityLease()

        // NWPathMonitor always emits its current state after start. That first callback establishes
        // the baseline only; neither an online nor offline baseline is a path transition.
        guard let previous else { return }
        guard satisfied else {
            startSupervisors(
                stableObserverIDs(),
                trigger: .contextChanged,
                runEpoch: runEpoch
            )
            return
        }
        guard previous == false else { return }
        scheduleAttention(.networkRestored, runEpoch: runEpoch)
    }

    private func scheduleAttention(_ trigger: PollTrigger, runEpoch: UInt64) {
        guard isActiveRun(runEpoch) else { return }
        pendingWake?.cancel()
        let clock = clock
        pendingWake = Task { @MainActor [weak self] in
            let deadline = clock.adding(PollingPolicy.wakeCoalesce, to: clock.now())
            do {
                try await clock.sleep(until: deadline, tolerance: .seconds(1))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.isActiveRun(runEpoch)
            else { return }
            self.pendingWake = nil
            self.startSupervisors(
                self.stableObserverIDs(),
                trigger: trigger,
                runEpoch: runEpoch
            )
        }
    }

    private func stableObserverIDs() -> [AccountID] {
        knownConfigs.keys.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
    }
}
