import Foundation
import QotaFolioCore
import Synchronization

public nonisolated protocol BrowserOpening: Sendable {
  func open(_ url: URL) async -> Bool
}

public nonisolated protocol MonotonicClock: Sendable {
  var now: ContinuousClock.Instant { get }
  func sleep(until deadline: ContinuousClock.Instant) async throws
}

public nonisolated extension MonotonicClock {
  func elapsedMS(since start: ContinuousClock.Instant) -> Int {
    let (seconds, attoseconds) = start.duration(to: now).components
    guard seconds > 0 || (seconds == 0 && attoseconds >= 0) else { return 0 }
    guard seconds <= (Int64.max - 1000) / 1000 else { return .max }
    return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
  }
}

public nonisolated protocol RandomBytesGenerating: Sendable {
  func bytes(_ count: Int) -> Data
}

public nonisolated protocol AnthropicCallbackListening: Sendable {
  func startIPv4Only(expectedState: SecretString) async throws -> AnthropicListenerReady
  func awaitCallback() async throws -> AnthropicCallbackOutcome
  func stop() async
}

public nonisolated struct AnthropicListenerReady: Sendable {
  public let port: UInt16
  public let redirectURI: URL

  public init(port: UInt16, redirectURI: URL) {
    self.port = port
    self.redirectURI = redirectURI
  }
}

// This is `public`, so its shape is exported to every consumer of
// QotaFolioKit, and it carries a LIVE authorization code. The payload is the carrier type.
public nonisolated enum AnthropicCallbackOutcome: Sendable {
  case authorized(code: SecretString)
  case denied
}

public nonisolated struct UsageRequestID: RawRepresentable, Hashable, Sendable, Comparable {
  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  public static func < (lhs: UsageRequestID, rhs: UsageRequestID) -> Bool {
    lhs.rawValue.uuidString < rhs.rawValue.uuidString
  }
}

public nonisolated enum UsageRequestResult: Sendable {
  case success(UsageSnapshot)
  case failure(UsageProviderError)
  case cancelled
}

public nonisolated enum UsageRequestDrainResult: Sendable {
  case drained(UsageRequestResult)
}

private nonisolated final class RequestCancellationGate: Sendable {
  private let action: Mutex<(@Sendable () -> Void)?>

  init(_ action: @escaping @Sendable () -> Void) {
    self.action = Mutex(action)
  }

  func cancel() {
    let action = action.withLock { action -> (@Sendable () -> Void)? in
      defer { action = nil }
      return action
    }
    action?()
  }
}

/// A repeatable, cancellation-aware observation of one usage operation.
/// Construction stays inside QotaFolioKit so every accepted production request has these semantics.
public nonisolated final class CancellableUsageRequest: Sendable {
  public let id: UsageRequestID

  private let terminalTask: Task<UsageRequestResult, Never>
  private let cancellation: RequestCancellationGate

  init(
    id: UsageRequestID,
    onCancel: @escaping @Sendable () -> Void = {},
    operation: @escaping @Sendable () async -> UsageRequestResult
  ) {
    self.id = id
    self.cancellation = RequestCancellationGate(onCancel)
    self.terminalTask = Task { @concurrent in
      await operation()
    }
  }

  init(id: UsageRequestID, terminal: UsageRequestResult) {
    self.id = id
    self.cancellation = RequestCancellationGate({})
    self.terminalTask = Task { @concurrent in terminal }
  }

  public func result() async -> UsageRequestResult {
    await terminalTask.value
  }

  public func cancel() {
    cancellation.cancel()
    terminalTask.cancel()
  }

  public func cancelAndDrain() async -> UsageRequestDrainResult {
    cancel()
    return .drained(await terminalTask.value)
  }
}

public nonisolated protocol ProductionUsageProvider: UsageProvider {
  /// Starts one usage GET.
  ///
  /// The trigger travels with the request because the request has to decide something with it:
  /// `ProviderNetworkConstraints` reads it to say whether this poll may spend a constrained or
  /// an expensive network path. It is not carried for logging and it is not advisory — a poll
  /// nobody is waiting for does not go out over a tethered phone.
  func startUsageRequest(
    id: UsageRequestID,
    token: ValidAccessToken,
    trigger: PollTrigger
  ) -> CancellableUsageRequest
}

public nonisolated extension ProductionUsageProvider {
  /// The trigger-free entry point, for a caller that is a person waiting on an answer.
  ///
  /// `fetchUsage` is awaited by whoever called it, so `.manual` is the truth about it rather
  /// than a convenient default: a request with a caller blocked on its result is a request
  /// somebody is waiting for.
  func fetchUsage(token: ValidAccessToken) async throws -> UsageSnapshot {
    let handle = startUsageRequest(
      id: UsageRequestID(rawValue: UUID()),
      token: token,
      trigger: .manual
    )
    let result = await withTaskCancellationHandler {
      await handle.result()
    } onCancel: {
      handle.cancel()
    }

    if Task.isCancelled {
      _ = await handle.cancelAndDrain()
      throw CancellationError()
    }

    switch result {
    case .success(let snapshot):
      return snapshot
    case .failure(let error):
      throw error
    case .cancelled:
      throw CancellationError()
    }
  }
}

public nonisolated enum CancellableHTTPResult: Sendable {
  case response(Data, HTTPURLResponse)
  case failure(HTTPTransportError)
  case cancelled
}

/// A repeatable, cancellation-aware observation of one HTTP operation.
/// The operation closure is consumed once by a shared Task; all observers await that Task.
public nonisolated final class CancellableHTTPRequest: Sendable {
  public let id: UsageRequestID

  private let terminalTask: Task<CancellableHTTPResult, Never>
  private let cancellation: RequestCancellationGate

  init(
    id: UsageRequestID,
    onCancel: @escaping @Sendable () -> Void = {},
    operation: @escaping @Sendable () async -> CancellableHTTPResult
  ) {
    self.id = id
    self.cancellation = RequestCancellationGate(onCancel)
    self.terminalTask = Task { @concurrent in
      await operation()
    }
  }

  init(id: UsageRequestID, terminal: CancellableHTTPResult) {
    self.id = id
    self.cancellation = RequestCancellationGate({})
    self.terminalTask = Task { @concurrent in terminal }
  }

  public func result() async -> CancellableHTTPResult {
    await terminalTask.value
  }

  public func cancel() {
    cancellation.cancel()
    terminalTask.cancel()
  }

  public func cancelAndDrain() async -> CancellableHTTPResult {
    cancel()
    return await terminalTask.value
  }
}

public nonisolated protocol CancellableHTTPTransport: HTTPTransport {
  func start(
    _ request: URLRequest,
    id: UsageRequestID,
    maxResponseBytes: Int
  ) -> CancellableHTTPRequest
}

public nonisolated extension CancellableHTTPTransport {
  func send(
    _ request: URLRequest,
    maxResponseBytes: Int
  ) async throws -> (Data, HTTPURLResponse) {
    let handle = start(
      request,
      id: UsageRequestID(rawValue: UUID()),
      maxResponseBytes: maxResponseBytes
    )
    let result = await withTaskCancellationHandler {
      await handle.result()
    } onCancel: {
      handle.cancel()
    }

    if Task.isCancelled {
      _ = await handle.cancelAndDrain()
      throw CancellationError()
    }

    switch result {
    case .response(let data, let response):
      return (data, response)
    case .failure(let error):
      throw error
    case .cancelled:
      throw CancellationError()
    }
  }
}

public nonisolated struct AnyCancellableHTTPTransport: CancellableHTTPTransport {
  private let base: any CancellableHTTPTransport

  public init(_ base: any CancellableHTTPTransport) {
    self.base = base
  }

  public func send(
    _ request: URLRequest,
    maxResponseBytes: Int
  ) async throws -> (Data, HTTPURLResponse) {
    try await base.send(request, maxResponseBytes: maxResponseBytes)
  }

  public func start(
    _ request: URLRequest,
    id: UsageRequestID,
    maxResponseBytes: Int
  ) -> CancellableHTTPRequest {
    base.start(request, id: id, maxResponseBytes: maxResponseBytes)
  }
}

nonisolated extension CancellableUsageRequest {
  convenience init(
    id: UsageRequestID,
    underlying: CancellableHTTPRequest,
    transform: @escaping @Sendable (CancellableHTTPResult) -> UsageRequestResult
  ) {
    self.init(
      id: id,
      onCancel: { underlying.cancel() },
      operation: { transform(await underlying.result()) }
    )
  }
}

/// Test-only compatibility for existing UsageProvider doubles. Production construction never accepts this type.
nonisolated struct LegacyUsageProviderAdapter: ProductionUsageProvider {
  let provider: AccountProvider
  private let base: any UsageProvider

  init(_ base: any UsageProvider) {
    self.base = base
    self.provider = base.provider
  }

  func startUsageRequest(
    id: UsageRequestID,
    token: ValidAccessToken,
    trigger: PollTrigger
  ) -> CancellableUsageRequest {
    // The adapter wraps a plain `UsageProvider`, which builds its own request and never sees
    // this. Production composition cannot name this type, so no shipping request loses its
    // constraints here.
    _ = trigger
    return CancellableUsageRequest(id: id) {
      do {
        return .success(try await base.fetchUsage(token: token))
      } catch is CancellationError {
        return .cancelled
      } catch let error as UsageProviderError {
        return .failure(error)
      } catch {
        return .failure(.temporarilyUnavailable)
      }
    }
  }
}
