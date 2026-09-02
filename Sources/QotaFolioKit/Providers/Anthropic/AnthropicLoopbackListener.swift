import Foundation
import Network
import QotaFolioCore

actor AnthropicLoopbackListener: AnthropicCallbackListening {
  private static let applicationReaderLimit = 8
  private static let frameworkConnectionLimit = 32
  private static let headerReadTimeout: Duration = .seconds(2)

  private let queue = DispatchQueue(label: "net.c2coast.QotaFolio.anthropic-loopback")
  private let listenerFactory: @Sendable (NWParameters) throws -> NWListener

  private var listener: NWListener?
  private var readyValue: AnthropicListenerReady?
  private var expectedState: SecretString?   // the live CSRF state of an in-flight transaction; the exact-callback validation below depends on its secrecy
  private var claimedOutcome: AnthropicCallbackOutcome?
  private var terminalState: TerminalState?
  private var startContinuation: CheckedContinuation<AnthropicListenerReady, any Error>?
  private var callbackContinuation: CheckedContinuation<AnthropicCallbackOutcome, any Error>?
  private var readers = [UUID: LoopbackConnectionReader]()
  private var incompleteReaderOrder = [UUID]()

  init() {
    self.listenerFactory = { parameters in
      try NWListener(using: parameters, on: .any)
    }
  }

  /// Internal construction seam used only by artifact probes to force listener failures.
  init(listenerFactory: @escaping @Sendable (NWParameters) throws -> NWListener) {
    self.listenerFactory = listenerFactory
  }

  func startIPv4Only(expectedState: SecretString) async throws -> AnthropicListenerReady {
    guard !expectedState.isEmpty else {
      throw AnthropicLoopbackListenerError.stateChanged
    }
    return try await start(expectedState: expectedState)
  }

  private func start(expectedState: SecretString) async throws -> AnthropicListenerReady {
    try throwIfTerminal()
    guard listener == nil, startContinuation == nil, readyValue == nil else {
      throw AnthropicLoopbackListenerError.alreadyStarted
    }

    guard self.expectedState == nil || self.expectedState == expectedState else {
      throw AnthropicLoopbackListenerError.stateChanged
    }
    // Actor isolation makes this assignment atomic with respect to connection
    // evaluation. It happens before the listener can accept a browser callback.
    self.expectedState = expectedState

    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    parameters.allowLocalEndpointReuse = false
    parameters.acceptLocalOnly = true

    let newListener: NWListener
    do {
      newListener = try listenerFactory(parameters)
    } catch {
      terminalState = .failed
      throw AnthropicLoopbackListenerError.unavailable
    }
    newListener.newConnectionLimit = Self.frameworkConnectionLimit
    listener = newListener

    newListener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      Task {
        await self.handleListenerState(state)
      }
    }
    newListener.newConnectionHandler = { [weak self] connection in
      guard let self else {
        connection.cancel()
        return
      }
      Task {
        await self.accept(connection)
      }
    }

    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        startContinuation = continuation
        if Task.isCancelled {
          startContinuation = nil
          listener = nil
          terminalState = .cancelled
          newListener.cancel()
          continuation.resume(throwing: CancellationError())
        } else {
          newListener.start(queue: queue)
        }
      }
    } onCancel: {
      Task {
        await self.cancelStartWait()
      }
    }
  }

  func awaitCallback() async throws -> AnthropicCallbackOutcome {
    if let terminalState {
      return try terminalState.outcome()
    }
    guard readyValue != nil else {
      throw AnthropicLoopbackListenerError.notStarted
    }
    guard expectedState != nil else {
      throw AnthropicLoopbackListenerError.stateNotArmed
    }
    guard callbackContinuation == nil else {
      throw AnthropicLoopbackListenerError.callbackWaitAlreadyActive
    }

    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        if let terminalState {
          continuation.resume(with: terminalState.result)
        } else if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          callbackContinuation = continuation
        }
      }
    } onCancel: {
      Task {
        await self.cancelCallbackWait()
      }
    }
  }

  func stop() async {
    await terminate(as: .cancelled)
  }

  private func handleListenerState(_ state: NWListener.State) async {
    guard terminalState == nil else { return }

    switch state {
    case .ready:
      guard let listener, let port = listener.port else {
        await failListener()
        return
      }
      let numericPort = port.rawValue
      guard numericPort > 0 else {
        await failListener()
        return
      }
      let redirectString = String(
        format: AnthropicWire.redirectURITemplate,
        Int(numericPort)
      )
      guard let redirectURI = URL(string: redirectString) else {
        await failListener()
        return
      }
      let ready = AnthropicListenerReady(port: numericPort, redirectURI: redirectURI)
      readyValue = ready
      resumeStart(returning: ready)

    case .failed, .waiting, .cancelled:
      // Explicit stop/completion sets terminalState before cancelling the listener.
      // Reaching these states without a terminal state is an unexpected listener loss.
      await failListener()

    case .setup:
      break

    @unknown default:
      await failListener()
    }
  }

  private func accept(_ connection: NWConnection) async {
    guard listener != nil, terminalState == nil, claimedOutcome == nil else {
      connection.cancel()
      return
    }

    var evictedReader: LoopbackConnectionReader?
    if readers.count >= Self.applicationReaderLimit {
      guard let oldestID = incompleteReaderOrder.first else {
        // All admitted readers have complete requests in their bounded response path.
        // Keep the resource cap rather than admitting an unbounded ninth reader.
        connection.cancel()
        return
      }
      incompleteReaderOrder.removeFirst()
      evictedReader = readers.removeValue(forKey: oldestID)
    }

    let id = UUID()
    let reader = LoopbackConnectionReader(
      id: id,
      connection: connection,
      queue: queue,
      maximumBytes: AnthropicWire.callbackRequestMaxBytes,
      headerReadTimeout: Self.headerReadTimeout,
      listener: self
    )
    readers[id] = reader
    incompleteReaderOrder.append(id)

    // State was updated before suspension, so reentrant accepts still observe a hard
    // application-level cap. A reader evicted before its delayed start sees `finished`.
    if let evictedReader {
      await evictedReader.cancel()
    }
    await reader.start()
  }

  fileprivate func evaluate(_ id: UUID, data: Data) -> LoopbackEvaluation {
    guard terminalState == nil, claimedOutcome == nil, readers[id] != nil else {
      return .discard
    }
    incompleteReaderOrder.removeAll { $0 == id }

    guard let readyValue, let expectedState else {
      return .reply(.badRequest)
    }

    let parsed = LoopbackRequestParser.parse(
      data,
      expectedPort: readyValue.port,
      expectedState: expectedState
    )
    switch parsed {
    case .authorized(let code):
      let outcome = AnthropicCallbackOutcome.authorized(code: code)
      claimedOutcome = outcome
      return .claim(outcome: outcome, response: .success)
    case .denied:
      let outcome = AnthropicCallbackOutcome.denied
      claimedOutcome = outcome
      return .claim(outcome: outcome, response: .denied)
    case .badRequest:
      return .reply(.badRequest)
    case .notFound:
      return .reply(.notFound)
    }
  }

  fileprivate func claimResponseDidFinish(_ outcome: AnthropicCallbackOutcome) async {
    guard terminalState == nil, claimedOutcome != nil else { return }
    terminalState = .completed(outcome)

    let pendingCallback = callbackContinuation
    callbackContinuation = nil
    let activeListener = listener
    listener = nil

    let activeReaders = Array(readers.values)
    readers.removeAll()
    incompleteReaderOrder.removeAll()

    activeListener?.cancel()
    for reader in activeReaders {
      await reader.cancel()
    }
    pendingCallback?.resume(returning: outcome)
  }

  fileprivate func readerDidFinish(_ id: UUID) {
    readers.removeValue(forKey: id)
    incompleteReaderOrder.removeAll { $0 == id }
  }

  private func failListener() async {
    await terminate(as: .failed)
  }

  private func cancelStartWait() async {
    await terminate(as: .cancelled)
  }

  private func cancelCallbackWait() async {
    await terminate(as: .cancelled)
  }

  private func terminate(as requestedState: TerminalState) async {
    switch terminalState {
    case nil:
      terminalState = requestedState
    case .some(.failed), .some(.completed):
      break
    case .some(.cancelled):
      if case .failed = requestedState {
        terminalState = .failed
      }
    }

    let activeListener = listener
    let pendingStart = startContinuation
    let pendingCallback = callbackContinuation
    listener = nil
    startContinuation = nil
    callbackContinuation = nil

    let activeReaders = Array(readers.values)
    readers.removeAll()
    incompleteReaderOrder.removeAll()

    activeListener?.cancel()
    for reader in activeReaders {
      await reader.cancel()
    }

    let result = terminalState?.result ?? .failure(CancellationError())
    pendingStart?.resume(throwing: result.failure ?? CancellationError())
    pendingCallback?.resume(with: result)
  }

  private func throwIfTerminal() throws {
    guard let terminalState else { return }
    switch terminalState {
    case .failed:
      throw AnthropicLoopbackListenerError.unavailable
    case .cancelled:
      throw CancellationError()
    case .completed:
      throw AnthropicLoopbackListenerError.alreadyStarted
    }
  }

  private func resumeStart(returning value: AnthropicListenerReady) {
    let continuation = startContinuation
    startContinuation = nil
    continuation?.resume(returning: value)
  }
}

private nonisolated enum TerminalState: Sendable {
  case failed
  case cancelled
  case completed(AnthropicCallbackOutcome)

  var result: Result<AnthropicCallbackOutcome, any Error> {
    switch self {
    case .failed:
      .failure(AnthropicLoopbackListenerError.unavailable)
    case .cancelled:
      .failure(CancellationError())
    case .completed(let outcome):
      .success(outcome)
    }
  }

  func outcome() throws -> AnthropicCallbackOutcome {
    try result.get()
  }
}

private nonisolated extension Result where Failure == any Error {
  var failure: (any Error)? {
    guard case .failure(let error) = self else { return nil }
    return error
  }
}

private nonisolated enum AnthropicLoopbackListenerError: Error, Sendable {
  case alreadyStarted
  case notStarted
  case stateNotArmed
  case callbackWaitAlreadyActive
  case stateChanged
  case unavailable
}

private actor LoopbackConnectionReader {
  let id: UUID
  let connection: NWConnection
  let queue: DispatchQueue
  let maximumBytes: Int
  let headerReadTimeout: Duration
  let listener: AnthropicLoopbackListener

  private var buffer = Data()
  private var receiving = false
  private var finished = false
  private var headerDeadlineTask: Task<Void, Never>?

  init(
    id: UUID,
    connection: NWConnection,
    queue: DispatchQueue,
    maximumBytes: Int,
    headerReadTimeout: Duration,
    listener: AnthropicLoopbackListener
  ) {
    self.id = id
    self.connection = connection
    self.queue = queue
    self.maximumBytes = maximumBytes
    self.headerReadTimeout = headerReadTimeout
    self.listener = listener
  }

  func start() {
    guard !finished, headerDeadlineTask == nil else { return }

    let deadline = ContinuousClock.now.advanced(by: headerReadTimeout)
    headerDeadlineTask = Task { [weak self] in
      do {
        try await ContinuousClock().sleep(until: deadline)
      } catch {
        return
      }
      guard let self else { return }
      await self.headerDeadlineReached()
    }

    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      Task {
        await self.handle(state)
      }
    }
    connection.start(queue: queue)
  }

  func cancel() async {
    finished = true
    let deadlineTask = headerDeadlineTask
    headerDeadlineTask = nil
    deadlineTask?.cancel()
    connection.cancel()
    if let deadlineTask {
      await deadlineTask.value
    }
  }

  private func handle(_ state: NWConnection.State) async {
    guard !finished else { return }
    switch state {
    case .ready:
      receiveNext()
    case .failed, .cancelled:
      await finish()
    case .setup, .preparing, .waiting:
      break
    @unknown default:
      await finish()
    }
  }

  private func receiveNext() {
    guard !finished, !receiving else { return }
    receiving = true
    let remaining = max(1, maximumBytes - buffer.count + 1)
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: min(4096, remaining)
    ) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      Task {
        await self.received(data: data, isComplete: isComplete, error: error)
      }
    }
  }

  private func received(data: Data?, isComplete: Bool, error: NWError?) async {
    receiving = false
    guard !finished else { return }
    if error != nil {
      await finish()
      return
    }
    if let data {
      buffer.append(data)
    }
    if buffer.count > maximumBytes {
      await respond(.badRequest, claimedOutcome: nil)
      return
    }

    let delimiter = Data("\r\n\r\n".utf8)
    if let range = buffer.range(of: delimiter) {
      let headerEnd = range.upperBound
      guard headerEnd == buffer.endIndex else {
        await respond(.badRequest, claimedOutcome: nil)
        return
      }
      let evaluation = await listener.evaluate(id, data: buffer)
      switch evaluation {
      case .discard:
        await finish()
      case .reply(let response):
        await respond(response, claimedOutcome: nil)
      case .claim(let outcome, let response):
        await respond(response, claimedOutcome: outcome)
      }
      return
    }

    if isComplete {
      await respond(.badRequest, claimedOutcome: nil)
    } else {
      receiveNext()
    }
  }

  private func respond(
    _ response: LoopbackHTTPResponse,
    claimedOutcome: AnthropicCallbackOutcome?
  ) async {
    guard !finished else { return }
    finished = true

    let deadlineTask = headerDeadlineTask
    headerDeadlineTask = nil
    deadlineTask?.cancel()
    if let deadlineTask {
      await deadlineTask.value
    }

    let wire = response.wireData
    connection.send(
      content: wire,
      contentContext: .finalMessage,
      isComplete: true,
      completion: .contentProcessed { [weak self] _ in
        guard let self else { return }
        Task {
          await self.responseFinished(claimedOutcome: claimedOutcome)
        }
      }
    )
  }

  private func responseFinished(claimedOutcome: AnthropicCallbackOutcome?) async {
    connection.cancel()
    if let claimedOutcome {
      await listener.claimResponseDidFinish(claimedOutcome)
    } else {
      await listener.readerDidFinish(id)
    }
  }

  private func headerDeadlineReached() async {
    guard !finished else { return }
    headerDeadlineTask = nil
    finished = true
    connection.cancel()
    await listener.readerDidFinish(id)
  }

  private func finish() async {
    guard !finished else { return }
    finished = true

    let deadlineTask = headerDeadlineTask
    headerDeadlineTask = nil
    deadlineTask?.cancel()
    connection.cancel()
    if let deadlineTask {
      await deadlineTask.value
    }
    await listener.readerDidFinish(id)
  }
}

private nonisolated enum LoopbackEvaluation: Sendable {
  case discard
  case reply(LoopbackHTTPResponse)
  case claim(outcome: AnthropicCallbackOutcome, response: LoopbackHTTPResponse)
}

nonisolated enum LoopbackRequestResult: Sendable {   // module-internal, not file-private: the redaction suite executes the four printing paths against a populated instance of this type
  case authorized(code: SecretString)
  case denied
  case badRequest
  case notFound
}

nonisolated enum LoopbackRequestParser {   // module-internal: the CSRF-state gate is exercised directly by the domain tests
  static func parse(
    _ data: Data,
    expectedPort: UInt16,
    expectedState: SecretString
  ) -> LoopbackRequestResult {
    guard let request = String(data: data, encoding: .utf8) else { return .badRequest }
    let lines = request.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return .badRequest }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard requestParts.count == 3 else { return .badRequest }
    guard requestParts[0] == "GET" else { return .badRequest }
    guard requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0" else {
      return .badRequest
    }

    let target = String(requestParts[1])
    guard !target.contains("#"), let components = URLComponents(string: target) else {
      return .badRequest
    }
    guard components.scheme == nil, components.host == nil, components.path == "/callback" else {
      return components.path == "/callback" ? .badRequest : .notFound
    }

    var headers = [String: [String]]()
    for line in lines.dropFirst() where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { return .badRequest }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty else { return .badRequest }
      headers[name, default: []].append(value)
    }

    guard
      let hosts = headers["host"],
      hosts.count == 1,
      hosts[0].lowercased() == "localhost:\(expectedPort)"
    else {
      return .badRequest
    }
    guard headers["transfer-encoding"] == nil else { return .badRequest }
    if let lengths = headers["content-length"] {
      guard lengths.count == 1, lengths[0] == "0" else { return .badRequest }
    }

    let items = components.queryItems ?? []
    let states = items.filter { $0.name == "state" }
    let codes = items.filter { $0.name == "code" }
    let errors = items.filter { $0.name == "error" }
    guard states.count == 1,
          let observedState = states[0].value,
          SecretString(observedState) == expectedState else { return .badRequest }
    guard codes.count <= 1, errors.count <= 1, codes.isEmpty || errors.isEmpty else {
      return .badRequest
    }

    if let code = codes.first?.value, !code.isEmpty {
      return .authorized(code: SecretString(code))
    }
    if let error = errors.first?.value, !error.isEmpty {
      return .denied
    }
    return .badRequest
  }
}

private nonisolated struct LoopbackHTTPResponse: Sendable {
  let status: Int
  let reason: String
  let contentType: String
  let body: Data

  static let success = Self.html(
    status: 200,
    reason: "OK",
    message: "Authorization received. You can return to QotaFolio."
  )
  static let denied = Self.html(
    status: 200,
    reason: "OK",
    message: "Authorization was denied. You can return to QotaFolio."
  )
  static let badRequest = Self.text(status: 400, reason: "Bad Request")
  static let notFound = Self.text(status: 404, reason: "Not Found")

  var wireData: Data {
    var result = Data(
      "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8
    )
    result.append(body)
    return result
  }

  private static func html(status: Int, reason: String, message: String) -> Self {
    let escaped = message
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
    return Self(
      status: status,
      reason: reason,
      contentType: "text/html; charset=utf-8",
      body: Data("<!doctype html><meta charset=utf-8><title>QotaFolio</title><p>\(escaped)</p>".utf8)
    )
  }

  private static func text(status: Int, reason: String) -> Self {
    Self(
      status: status,
      reason: reason,
      contentType: "text/plain; charset=utf-8",
      body: Data("\(reason)\n".utf8)
    )
  }
}
