import AppKit
import Dispatch
import Synchronization
import QotaFolioCore
import QotaFolioKit

/// Asks AppKit to terminate from the run loop instead of from the caller's main-queue block.
///
/// `applicationShouldTerminate` answers `.terminateLater`, and AppKit then spins a nested run
/// loop until `reply(toApplicationShouldTerminate:)` arrives. That reply is produced by a
/// MainActor task, and every MainActor task body is a main-queue block. libdispatch does not
/// drain the main queue reentrantly, so a `terminate` issued from inside a main-queue block
/// spins a loop that can never run the task that would end it: the app hangs in
/// `terminateLater` forever. Handing the call to the run loop first puts that nested loop
/// outside any main-queue block, and the reply gets through.
@MainActor
func requestApplicationTermination() {
    RunLoop.main.perform(inModes: [.common]) {
        MainActor.assumeIsolated {
            NSApp.terminate(nil)
        }
    }
}

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    private var container: AppContainer?
    private var lease: SingleInstanceLease?
    private var startupTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?

    /// A reveal that arrived before there was anything to reveal.
    ///
    /// Startup reconciles credentials before the status item exists, and that window is exactly
    /// when a user who saw nothing happen launches the app again. Dropping the request there
    /// would restore that silence, so it is held and spent once the runtime is up.
    private var revealIsPending = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            switch try SingleInstanceLease.acquire() {
            case .acquired(let lease):
                self.lease = lease
                lease.observeDoorbell { [weak self] in
                    self?.revealRunningInstance()
                }
            case .alreadyRunning(let doorbell):
                // The user asked for QotaFolio and QotaFolio is already here. This process has
                // no window and no Dock icon of its own, so standing down in silence leaves
                // the user unable to tell the app is running. Ring the instance that can show
                // itself, then leave. A ring that fails is reported through the launch-failure
                // alert rather than swallowed.
                try doorbell.ring()
                requestApplicationTermination()
            }
        } catch {
            presentLaunchFailure(error.localizedDescription)
            requestApplicationTermination()
        }
    }

    /// Finder, the Dock and Spotlight all send this when the user opens an app that is already
    /// running, and macOS does not start a second process for it. For an app whose only surface
    /// is a menu-bar panel, showing that panel is the entire correct answer.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        revealRunningInstance()
        // AppKit still does its ordinary pass over any windows the app does have — the Settings
        // window is deminiaturized and ordered front, which is what a reopen means for it.
        return true
    }

    private func revealRunningInstance() {
        guard let container else {
            revealIsPending = true
            return
        }
        container.revealPrimarySurface()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No lease, no app: another instance already holds it and this process is on its way out.
        guard lease != nil, startupTask == nil else { return }

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let container = try await AppContainer.make()
                guard !Task.isCancelled, self.terminationTask == nil else { return }
                self.container = container
                container.start()
                if self.revealIsPending {
                    self.revealIsPending = false
                    container.revealPrimarySurface()
                }
            } catch is CancellationError {
                return
            } catch {
                self.presentLaunchFailure(error.localizedDescription)
                requestApplicationTermination()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The quit, and the one thing it will not do: refuse.
    ///
    /// The one refusal is `Uninstall` between deleting the Keychain items and removing the
    /// files: quitting inside that window would leave the removal half-done with no way back. The
    /// removal ends on its own and puts a Quit button in front of the user, so the quit that comes
    /// again succeeds.
    ///
    /// **It lasts at most ten seconds**, which is five steps at the two-second drain deadline
    /// apiece, against milliseconds in the ordinary case.
    ///
    /// **The wait below is one budget, not two in series.** A static reading pairs the two-second
    /// startup deadline with the runtime's five-second termination budget and gets seven seconds.
    /// They cannot both be spent: the startup task installs a container only while
    /// `terminationTask` is nil, and that field is assigned before this task's body runs. So
    /// either startup finished first — and `awaitStartupWithinDeadline` returns at once on a task
    /// that has already ended — or it did not, in which case it will never install a container and
    /// `beginOrdinaryTermination` has nothing to drain. Worst case is five seconds.
    ///
    /// A startup still in flight does not refuse the quit. Everything the startup task holds goes
    /// with the process: it opens no status item, starts no polling, and the one write it can be
    /// inside, the credential reconcile, is idempotent and redone on the next launch.
    ///
    /// The reply below is unconditional and is meant to read that way.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        if let container, !container.ordinaryTerminationIsAllowed {
            return .terminateCancel
        }
        terminationTask = Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            // The answer is used to decide whether the handle can be dropped, and for nothing
            // else. A startup that outruns its deadline does not hold up the shutdown.
            if await self.awaitStartupWithinDeadline() {
                self.startupTask = nil
            }
            await self.container?.beginOrdinaryTermination()
            self.container = nil
            self.lease = nil
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Cancels the startup task and waits a bounded time for it to return.
    ///
    /// The handle is kept when the deadline wins. Startup reconciles credentials, so a
    /// Keychain call that ignores cancellation can outlive the deadline; cancelling and then
    /// dropping the reference would make that task unreachable for the next attempt.
    private func awaitStartupWithinDeadline() async -> Bool {
        startupTask?.cancel()
        guard let startupTask else { return true }
        let finished = await awaitWithinTerminationDeadline(TERMINATION_DRAIN_TIMEOUT) {
            await startupTask.value
            return true
        }
        return finished == true
    }

    /// The one message that says QotaFolio could not start, made visible.
    ///
    /// This runs from `applicationWillFinishLaunching`, before the run loop starts, in an
    /// accessory app that has never been frontmost. `runModal` orders the alert front inside an
    /// inactive app, which puts it behind whatever the user is actually looking at, so the one
    /// path that reports a failed launch is the one most likely to be invisible. Activating
    /// first is what puts it where the user is looking.
    private func presentLaunchFailure(_ detail: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "QotaFolio could not start"
        alert.informativeText = detail
        alert.runModal()
    }
}
