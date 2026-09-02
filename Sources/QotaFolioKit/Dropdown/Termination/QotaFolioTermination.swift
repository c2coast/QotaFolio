import AppKit

/// Asks AppKit to terminate from the run loop instead of from the caller's main-queue block.
///
/// `applicationShouldTerminate` answers `.terminateLater`, and AppKit then spins a nested run loop
/// until `reply(toApplicationShouldTerminate:)` arrives. That reply is produced by a MainActor
/// task, and every MainActor task body is a main-queue block. libdispatch does not drain the main
/// queue reentrantly, so a `terminate` issued from inside a main-queue block spins a loop that can
/// never run the task that would end it. The app hangs in `terminateLater` for good — a spindump
/// of the hang shows the main thread parked in a nested `CFRunLoop` and nothing else moving.
///
/// AppKit dispatches a SwiftUI button action from the run loop rather than from a task, which is
/// a property of those call sites and not of the call: the first `Task { … }` wrapped around one
/// of them deadlocks the app, and nothing about `NSApp.terminate(nil)` warns anybody. Handing the
/// call to the run loop first puts the nested loop outside any main-queue block, and the reply
/// gets through from either kind of caller.
///
/// The app target has its own `requestApplicationTermination()`, which does exactly this.
/// QotaFolioKit cannot see it — Kit is below the app in the dependency graph — so the panel needs
/// its own. The two are deliberately named apart so that a call in the app target can never be
/// read as resolving to whichever declaration the reader happened to think of.
@MainActor
public func requestQotaFolioTermination() {
    RunLoop.main.perform(inModes: [.common]) {
        MainActor.assumeIsolated {
            NSApp.terminate(nil)
        }
    }
}
