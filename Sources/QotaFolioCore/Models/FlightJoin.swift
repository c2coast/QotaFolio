import Synchronization

// Waiting on work that somebody else owns, in a way the waiter can leave.
//
// Three places in this app coalesce work behind one shared task and let several callers wait on
// it: the vault's refresh flight, the polling engine's usage flight, and the lifecycle
// coordinator's retiring add attempt. All three want the same thing.
//
// `await task.value` neither throws when the *awaiting* task is cancelled nor returns early, so a
// cancelled caller stays suspended until the shared work ends on its own. That is what this file
// is for — the primitive lives once, where the next join can find it, instead of being
// rediscovered a thousand lines away.

/// Waits on a task somebody else owns, and returns at once when this caller is cancelled.
///
/// Cancellation is deliberately one-directional. The waiter leaves; the task is untouched, so
/// every other waiter still gets its result — and work worth coalescing is still worth finishing
/// after its last waiter has gone, because the next caller would otherwise have to repeat it.
///
/// Wrapping `task.value` in `withTaskCancellationHandler` with an empty `onCancel` is not enough
/// on its own: that moves the throw to after the task ends, which is exactly the wait the caller
/// wanted to escape. Filling a continuation from `onCancel` is what makes the return prompt.
public nonisolated func joinFlight<Success: Sendable>(
    _ task: Task<Success, any Error>
) async throws -> Success {
    let join = FlightJoin<Success>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            join.install(continuation)
            // Unstructured and `@concurrent` on purpose. An unstructured task does not inherit
            // its parent's cancellation, so cancelling the waiter cannot cancel the observer that
            // is still carrying the result to the other waiters; `@concurrent` keeps the observer
            // off whatever actor the waiter was running on, which may be the one that is blocked.
            Task { @concurrent in join.settle(await task.result) }
        }
    } onCancel: {
        join.cancel()
    }
}

/// The same escape, for a flight that cannot fail.
///
/// `CancellationError` is then the only thing this can throw, which is why the call sites for a
/// `Task<Void, Never>` read `try? await joinFlight(…)`: there is no other error to swallow.
public nonisolated func joinFlight<Success: Sendable>(
    _ task: Task<Success, Never>
) async throws -> Success {
    let join = FlightJoin<Success>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            join.install(continuation)
            Task { @concurrent in join.settle(.success(await task.value)) }
        }
    } onCancel: {
        join.cancel()
    }
}

/// A one-shot cell that the flight's result or the waiter's cancellation can fill, whichever
/// comes first.
private nonisolated final class FlightJoin<Success: Sendable>: Sendable {
    typealias Waiter = CheckedContinuation<Success, any Error>

    private enum State {
        case idle
        case waiting(Waiter)
        case cancelledBeforeWaiting
        case settled
    }

    private let state = Mutex<State>(.idle)

    /// Called once, synchronously, before the observer task exists — so no result can arrive first.
    func install(_ continuation: Waiter) {
        let alreadyCancelled = state.withLock { state -> Bool in
            switch state {
            case .idle:
                state = .waiting(continuation)
                return false
            case .cancelledBeforeWaiting:
                state = .settled
                return true
            case .waiting, .settled:
                return false
            }
        }
        if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
    }

    func cancel() {
        let waiter = takeWaiterCancelling()
        waiter?.resume(throwing: CancellationError())
    }

    func settle(_ result: Result<Success, any Error>) {
        let waiter = state.withLock { state -> Waiter? in
            defer { state = .settled }
            guard case .waiting(let waiter) = state else { return nil }
            return waiter
        }
        waiter?.resume(with: result)
    }

    private func takeWaiterCancelling() -> Waiter? {
        state.withLock { state -> Waiter? in
            switch state {
            case .idle:
                state = .cancelledBeforeWaiting
                return nil
            case .waiting(let waiter):
                state = .settled
                return waiter
            case .cancelledBeforeWaiting, .settled:
                return nil
            }
        }
    }
}
