import AppKit
import Foundation
import QotaFolioCore
import Synchronization

public nonisolated struct SystemMonotonicClock: MonotonicClock {
  public init() {}

  public var now: ContinuousClock.Instant {
    ContinuousClock.now
  }

  public func sleep(until deadline: ContinuousClock.Instant) async throws {
    try await ContinuousClock().sleep(until: deadline)
  }
}

public nonisolated struct SystemRandomBytes: RandomBytesGenerating {
  public init() {}

  public func bytes(_ count: Int) -> Data {
    guard count > 0 else { return Data() }
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in
      UInt8.random(in: .min ... .max, using: &generator)
    })
  }
}

public nonisolated struct WorkspaceBrowserOpener: BrowserOpening {
  private let openWorkspace: @MainActor @Sendable (URL) -> Bool

  public init() {
    openWorkspace = { url in
      NSWorkspace.shared.open(url)
    }
  }

  init(openWorkspace: @escaping @MainActor @Sendable (URL) -> Bool) {
    self.openWorkspace = openWorkspace
  }

  public func open(_ url: URL) async -> Bool {
    await MainActor.run {
      guard !Task.isCancelled else { return false }
      return openWorkspace(url)
    }
  }
}

/// One provider HTTP transfer: the per-request state behind a single `URLSessionDataTask`.
///
/// The data task is created lazily, by `result()`, and only when the transfer has not already been
/// cancelled. That ordering is what makes cancel-before-start terminal on its own: no task is
/// created, nothing is registered with the router, no byte reaches the network, and `cancel()`
/// itself resumes the waiting continuation. Nothing on that path waits for a delegate callback.
///
/// Once the task is resumed, URLSession owns the terminal transition and always delivers one, with
/// `timeoutIntervalForResource` as the hard bound. Waiting for that callback is the URLSession
/// contract for a running transfer, not a hope: it is the only path that can tell the drain the
/// socket is finished with.
///
/// This type deliberately has no `deinit`. It owns no releasable resource: the session belongs to
/// the transport and is released there, the data task belongs to the session, and the continuation
/// cannot outlive the transfer because the task awaiting it holds the transfer.
nonisolated final class ChunkedURLSessionRequest: Sendable {
  private struct State: Sendable {
    var task: URLSessionDataTask?
    var response: HTTPURLResponse?
    var body: Data
    var pendingFailure: HTTPTransportError?
    var cancellationRequested = false
    var transferBegun = false
    var continuation: CheckedContinuation<CancellableHTTPResult, Never>?
    var terminal: CancellableHTTPResult?

    init(maxResponseBytes: Int) {
      body = Data()
      body.reserveCapacity(min(max(maxResponseBytes, 0), 64 * 1024))
    }
  }

  private typealias Completion = (
    CancellableHTTPResult,
    CheckedContinuation<CancellableHTTPResult, Never>?
  )

  private let session: URLSession
  private let router: ChunkedResponseRouter
  private let request: URLRequest
  private let maxResponseBytes: Int
  private let effectiveMaxResponseBytes: Int
  private let onDataChunk: (@Sendable (Int) -> Void)?
  private let state: Mutex<State>

  init(
    session: URLSession,
    router: ChunkedResponseRouter,
    request: URLRequest,
    maxResponseBytes: Int,
    onDataChunk: (@Sendable (Int) -> Void)?
  ) {
    self.session = session
    self.router = router
    self.request = request
    self.maxResponseBytes = maxResponseBytes
    self.effectiveMaxResponseBytes = max(maxResponseBytes, 0)
    self.onDataChunk = onDataChunk
    self.state = Mutex(State(maxResponseBytes: maxResponseBytes))
  }

  private enum Step: Sendable {
    case deliver(CancellableHTTPResult)
    case beginTransfer
  }

  func result() async -> CancellableHTTPResult {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let step = state.withLock { state -> Step in
          if let terminal = state.terminal {
            return .deliver(terminal)
          }
          precondition(state.continuation == nil)
          guard !state.cancellationRequested else {
            // Cancelled before this call, and no task exists, so record the outcome here.
            state.terminal = .cancelled
            return .deliver(.cancelled)
          }
          state.continuation = continuation
          state.transferBegun = true
          return .beginTransfer
        }

        switch step {
        case .deliver(let terminal):
          continuation.resume(returning: terminal)
        case .beginTransfer:
          beginTransfer()
        }
      }
    } onCancel: {
      cancel()
    }
  }

  func cancel() {
    let outcome = state.withLock { state -> (URLSessionDataTask?, Completion?) in
      guard state.terminal == nil, !state.cancellationRequested else {
        return (nil, nil)
      }
      state.cancellationRequested = true
      guard !state.transferBegun else {
        // `result()` owns the task. If it is already resumed, URLSession delivers the terminal
        // transition; if it has not created the task yet, `beginTransfer` reads this flag and
        // never resumes one.
        return (state.task, nil)
      }
      // Cancelled before any transfer began. No task exists, none will be created, and no delegate
      // callback is coming, so this call owns the terminal transition.
      return (nil, Self.finish(&state, with: .cancelled))
    }
    outcome.0?.cancel()
    Self.deliver(outcome.1)
  }

  /// Creates, registers and resumes the data task. Runs with no lock held.
  private func beginTransfer() {
    let task = session.dataTask(with: request)
    let identifier = task.taskIdentifier
    // Registration precedes `resume()`. A suspended task produces no delegate callback, so no
    // callback can arrive for `identifier` before the router can route it.
    router.register(self, forTaskIdentifier: identifier)

    let outcome = state.withLock { state -> (URLSessionDataTask?, Completion?) in
      guard state.terminal == nil, !state.cancellationRequested else {
        return (nil, Self.finish(&state, with: .cancelled))
      }
      state.task = task
      return (task, nil)
    }

    guard let resumable = outcome.0 else {
      // Cancellation landed while the task was being created. Deregister on this edge rather than
      // waiting for the completion callback of a task that never ran.
      router.deregister(taskIdentifier: identifier)
      task.cancel()
      Self.deliver(outcome.1)
      return
    }
    resumable.resume()
  }

  fileprivate func refuseRedirect(status: Int) -> URLSessionDataTask? {
    state.withLock { state in
      guard state.terminal == nil,
            state.pendingFailure == nil,
            !state.cancellationRequested
      else {
        return nil
      }
      state.pendingFailure = .redirectNotFollowed(status: status)
      return state.task
    }
  }

  fileprivate func evaluate(response: URLResponse) -> URLSession.ResponseDisposition {
    state.withLock { state in
      guard state.terminal == nil,
            state.pendingFailure == nil,
            !state.cancellationRequested
      else {
        return .cancel
      }
      guard let http = response as? HTTPURLResponse else {
        state.pendingFailure = .invalidResponse
        return .cancel
      }
      guard !(300..<400).contains(http.statusCode) else {
        state.pendingFailure = .redirectNotFollowed(status: http.statusCode)
        return .cancel
      }
      state.response = http
      return .allow
    }
  }

  /// Appends one response chunk. Returns true when the byte cap has been exceeded.
  fileprivate func append(_ data: Data) -> Bool {
    onDataChunk?(data.count)
    return state.withLock { state -> Bool in
      guard state.terminal == nil,
            state.pendingFailure == nil,
            !state.cancellationRequested
      else {
        return false
      }

      let remaining = effectiveMaxResponseBytes - state.body.count
      guard data.count <= remaining else {
        state.pendingFailure = .responseTooLarge(limit: maxResponseBytes)
        return true
      }
      state.body.append(data)
      return false
    }
  }

  fileprivate func complete(error: (any Error)?) {
    let completion = state.withLock { state -> Completion? in
      guard state.terminal == nil else {
        return nil
      }

      let result: CancellableHTTPResult
      if let pendingFailure = state.pendingFailure {
        result = .failure(pendingFailure)
      } else if state.cancellationRequested {
        result = .cancelled
      } else if let urlError = error as? URLError, urlError.code == .cancelled {
        result = .cancelled
      } else if let urlError = error as? URLError {
        result = .failure(.transport(underlying: urlError))
      } else if error != nil {
        result = .failure(.transport(underlying: URLError(.unknown)))
      } else if let response = state.response {
        result = .response(state.body, response)
      } else {
        result = .failure(.invalidResponse)
      }

      return Self.finish(&state, with: result)
    }
    Self.deliver(completion)
  }

  /// Records the single terminal outcome and hands back the waiting continuation, if any.
  /// Returns nil when a terminal outcome was already recorded.
  private static func finish(
    _ state: inout State,
    with result: CancellableHTTPResult
  ) -> Completion? {
    guard state.terminal == nil else { return nil }
    state.terminal = result
    state.task = nil
    state.response = nil
    state.body = Data()
    let continuation = state.continuation
    state.continuation = nil
    return (result, continuation)
  }

  private static func deliver(_ completion: Completion?) {
    guard let completion else { return }
    completion.1?.resume(returning: completion.0)
  }
}

/// The single `URLSessionDataDelegate` behind the transport's one session.
///
/// It routes callbacks to the transfer that owns the task and holds nothing else. Every registered
/// transfer is removed on its terminal edge — completion, or cancellation that lands while the task
/// is being created — so the registry returns to empty after every request.
nonisolated final class ChunkedResponseRouter: NSObject, URLSessionDataDelegate, Sendable {
  private let transfers = Mutex<[Int: ChunkedURLSessionRequest]>([:])

  func register(_ transfer: ChunkedURLSessionRequest, forTaskIdentifier identifier: Int) {
    transfers.withLock { transfers in
      transfers[identifier] = transfer
    }
  }

  func deregister(taskIdentifier identifier: Int) {
    transfers.withLock { transfers in
      _ = transfers.removeValue(forKey: identifier)
    }
  }

  /// The number of transfers the delegate is currently holding on the session's behalf.
  var registeredTransferCount: Int {
    transfers.withLock { $0.count }
  }

  private func transfer(forTaskIdentifier identifier: Int) -> ChunkedURLSessionRequest? {
    transfers.withLock { $0[identifier] }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    _ = session
    _ = request
    // Every redirect is refused, including one for a task this router cannot place. Following a 3xx
    // would carry the Authorization header to whatever host the response names.
    let dataTask = transfer(forTaskIdentifier: task.taskIdentifier)?
      .refuseRedirect(status: response.statusCode)
    completionHandler(nil)
    dataTask?.cancel()
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    _ = session
    guard let transfer = transfer(forTaskIdentifier: dataTask.taskIdentifier) else {
      completionHandler(.cancel)
      dataTask.cancel()
      return
    }
    let disposition = transfer.evaluate(response: response)
    completionHandler(disposition)
    if disposition == .cancel {
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    _ = session
    guard let transfer = transfer(forTaskIdentifier: dataTask.taskIdentifier) else {
      dataTask.cancel()
      return
    }
    if transfer.append(data) {
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    _ = session
    let transfer = transfers.withLock { transfers in
      transfers.removeValue(forKey: task.taskIdentifier)
    }
    transfer?.complete(error: error)
  }
}

/// The provider transport: one `URLSession` and one delegate for every request it will ever make.
///
/// URLSession keeps its HTTP connection pool and its TLS session-ticket cache per session, so a
/// session that lives for one request can reuse nothing and every poll pays a cold handshake. This
/// session is built once and lives as long as the transport, which is the whole process in the
/// shipping app. That also removes the per-request invalidation obligation entirely: no request
/// creates a session, so no request has to tear one down.
///
/// `URLSessionConfiguration.default` rather than `.ephemeral` is what keeps the ticket cache warm.
/// The explicit cache, cookie and credential settings below give the same privacy posture that
/// `.ephemeral` provided.
public nonisolated final class CancellableURLSessionTransport: CancellableHTTPTransport, Sendable {
  private let session: URLSession
  private let router: ChunkedResponseRouter
  private let onDataChunk: (@Sendable (Int) -> Void)?

  public convenience init(requestTimeout: TimeInterval = 60) {
    self.init(requestTimeout: requestTimeout, onDataChunk: nil)
  }

  init(
    requestTimeout: TimeInterval = 60,
    onDataChunk: (@Sendable (Int) -> Void)?
  ) {
    let timeout = max(1, requestTimeout)
    let configuration = URLSessionConfiguration.default
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout

    let router = ChunkedResponseRouter()
    self.router = router
    self.onDataChunk = onDataChunk
    self.session = URLSession(
      configuration: configuration,
      delegate: router,
      delegateQueue: nil
    )
  }

  deinit {
    // A delegate-backed URLSession holds its delegate until it is invalidated. This is the one
    // release the transport owes, it belongs to the object that created the session, and it does
    // not depend on any callback arriving. In-flight tasks still deliver their completions.
    session.finishTasksAndInvalidate()
  }

  /// Transfers the delegate is currently holding. Returns to zero after every request, including
  /// every cancelled one.
  var inFlightTransferCount: Int {
    router.registeredTransferCount
  }

  /// The delegate this transport owns. Its lifetime is the transport's: the session holds it until
  /// `deinit` invalidates the session.
  var responseRouter: ChunkedResponseRouter {
    router
  }

  /// Builds the transfer without the `CancellableHTTPRequest` wrapper.
  ///
  /// `start(_:id:maxResponseBytes:)` is exactly this plus the wrapper, so the cancel-before-start
  /// path is addressable without racing the wrapper's task.
  func makeTransfer(
    _ request: URLRequest,
    maxResponseBytes: Int
  ) -> ChunkedURLSessionRequest {
    ChunkedURLSessionRequest(
      session: session,
      router: router,
      request: request,
      maxResponseBytes: maxResponseBytes,
      onDataChunk: onDataChunk
    )
  }

  public func start(
    _ request: URLRequest,
    id: UsageRequestID,
    maxResponseBytes: Int
  ) -> CancellableHTTPRequest {
    let transfer = makeTransfer(request, maxResponseBytes: maxResponseBytes)
    return CancellableHTTPRequest(
      id: id,
      onCancel: { transfer.cancel() },
      operation: { await transfer.result() }
    )
  }
}
