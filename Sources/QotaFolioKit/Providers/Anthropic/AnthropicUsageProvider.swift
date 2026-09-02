import Foundation
import QotaFolioCore

public nonisolated struct AnthropicUsageProvider: UsageProvider {
  public let provider: AccountProvider = .anthropic

  private let transport: any HTTPTransport
  private let core: AnthropicUsageRequestCore

  public init(
    transport: any HTTPTransport,
    appVersion: String,
    now: @escaping @Sendable () -> Date,
    clock: any MonotonicClock,
    log: any RedactingLog
  ) {
    self.transport = transport
    self.core = AnthropicUsageRequestCore(
      appVersion: appVersion,
      now: now,
      clock: clock,
      log: log
    )
  }

  public func fetchUsage(token: ValidAccessToken) async throws -> UsageSnapshot {
    guard let request = core.makeRequest(token: token) else {
      throw UsageProviderError.configuration
    }

    try Task.checkCancellation()
    let started = core.clock.now

    do {
      let response = try await transport.send(
        request,
        maxResponseBytes: AnthropicWire.usageMaxResponseBytes
      )
      try Task.checkCancellation()
      return try core.snapshot(from: core.map(response: response, started: started))
    } catch is CancellationError {
      throw CancellationError()
    } catch let failure as UsageProviderError {
      throw failure
    } catch let error as HTTPTransportError {
      try Task.checkCancellation()
      return try core.snapshot(from: core.map(transportError: error, started: started))
    } catch {
      try Task.checkCancellation()
      return try core.snapshot(from: core.mapUnknownFailure(started: started))
    }
  }
}

public nonisolated struct AnthropicProductionUsageProvider: ProductionUsageProvider {
  public let provider: AccountProvider = .anthropic

  private let transport: AnyCancellableHTTPTransport
  private let core: AnthropicUsageRequestCore

  public init(
    transport: any CancellableHTTPTransport,
    appVersion: String,
    now: @escaping @Sendable () -> Date,
    clock: any MonotonicClock,
    log: any RedactingLog
  ) {
    self.transport = AnyCancellableHTTPTransport(transport)
    self.core = AnthropicUsageRequestCore(
      appVersion: appVersion,
      now: now,
      clock: clock,
      log: log
    )
  }

  public func startUsageRequest(
    id: UsageRequestID,
    token: ValidAccessToken,
    trigger: PollTrigger
  ) -> CancellableUsageRequest {
    guard !Task.isCancelled else {
      return CancellableUsageRequest(id: id, terminal: .cancelled)
    }
    guard var request = core.makeRequest(token: token) else {
      return CancellableUsageRequest(id: id, terminal: .failure(.configuration))
    }
    // The cadence poll is the only request in this app that recurs whether or not anyone is
    // looking, so it is the only one that has to ask what the network costs.
    ProviderNetworkConstraints.apply(to: &request, trigger: trigger)

    let started = core.clock.now
    let underlying = transport.start(
      request,
      id: id,
      maxResponseBytes: AnthropicWire.usageMaxResponseBytes
    )
    return CancellableUsageRequest(id: underlying.id, underlying: underlying) { result in
      switch result {
      case .response(let body, let response):
        return core.map(response: (body, response), started: started)
      case .failure(let error):
        return core.map(transportError: error, started: started)
      case .cancelled:
        return .cancelled
      }
    }
  }
}

private nonisolated struct AnthropicUsageRequestCore: Sendable {
  let appVersion: String
  let now: @Sendable () -> Date
  let clock: any MonotonicClock
  let log: any RedactingLog

  func makeRequest(token: ValidAccessToken) -> URLRequest? {
    guard case .anthropic(let accessToken, _) = token else {
      emitRefused()
      return nil
    }
    guard let userAgent = ProductUserAgent.value(appVersion: appVersion) else {
      emitRefused()
      return nil
    }
    guard let url = URL(string: AnthropicWire.usageURL) else {
      emitRefused()
      return nil
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(AnthropicWire.usageBetaHeader, forHTTPHeaderField: "anthropic-beta")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    // Anthropic's own header for a consumer to name itself. `ProductUserAgent` has already
    // proved the version is header-safe, so the value cannot carry a newline into a header.
    request.setValue(
      "QotaFolio/\(appVersion)",
      forHTTPHeaderField: AnthropicWire.clientAppHeaderName
    )
    accessToken.withUnsafeRawValue {
      request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  func map(
    response: (Data, HTTPURLResponse),
    started: ContinuousClock.Instant
  ) -> UsageRequestResult {
    let body = response.0
    let http = response.1
    let receivedAt = now()
    let retryAfter = RetryAfter.parse(
      http.value(forHTTPHeaderField: "Retry-After"),
      now: receivedAt
    )
    let durationMS = clock.elapsedMS(since: started)
    let sizeBucket = diagnosticSizeBucket(forByteCount: body.count)

    switch ProviderUsageErrorPolicy.disposition(
      status: http.statusCode,
      retryAfter: retryAfter
    ) {
    case .fail(let failure):
      emit(
        outcome: outcome(for: failure),
        status: http.statusCode,
        durationMS: durationMS,
        sizeBucket: sizeBucket,
        schemaFamily: nil
      )
      return .failure(failure)

    case .parseBody:
      do {
        let parsed = try AnthropicUsageParser.parse(body, fetchedAt: receivedAt)
        emit(
          outcome: .ok,
          status: http.statusCode,
          durationMS: durationMS,
          sizeBucket: sizeBucket,
          schemaFamily: parsed.schemaFamily
        )
        return .success(parsed.snapshot)
      } catch is CancellationError {
        return .cancelled
      } catch {
        emit(
          outcome: .permanent,
          status: http.statusCode,
          durationMS: durationMS,
          sizeBucket: sizeBucket,
          schemaFamily: nil
        )
        return .failure(.invalidPayload)
      }
    }
  }

  func map(
    transportError error: HTTPTransportError,
    started: ContinuousClock.Instant
  ) -> UsageRequestResult {
    let failure = ProviderUsageErrorPolicy.mapTransportError(error)
    emit(
      outcome: outcome(for: failure),
      status: nil,
      durationMS: clock.elapsedMS(since: started),
      sizeBucket: nil,
      schemaFamily: nil
    )
    return .failure(failure)
  }

  func mapUnknownFailure(started: ContinuousClock.Instant) -> UsageRequestResult {
    emit(
      outcome: .transient,
      status: nil,
      durationMS: clock.elapsedMS(since: started),
      sizeBucket: nil,
      schemaFamily: nil
    )
    return .failure(.temporarilyUnavailable)
  }

  func snapshot(from result: UsageRequestResult) throws -> UsageSnapshot {
    switch result {
    case .success(let snapshot):
      return snapshot
    case .failure(let error):
      throw error
    case .cancelled:
      throw CancellationError()
    }
  }

  private func emitRefused() {
    log.emit(
      DiagEvent(
        provider: .anthropic,
        operation: .usageGET,
        outcome: .refused,
        host: AnthropicWire.usageHost,
        path: AnthropicWire.usagePath
      )
    )
  }

  private func emit(
    outcome: DiagOutcome,
    status: Int?,
    durationMS: Int,
    sizeBucket: Int?,
    schemaFamily: StaticString?
  ) {
    log.emit(
      DiagEvent(
        provider: .anthropic,
        operation: .usageGET,
        outcome: outcome,
        host: AnthropicWire.usageHost,
        path: AnthropicWire.usagePath,
        httpStatus: status,
        durationMS: durationMS,
        sizeBucket: sizeBucket,
        schemaFamily: schemaFamily
      )
    )
  }

  private func outcome(for error: UsageProviderError) -> DiagOutcome {
    switch error {
    case .invalidPayload:
      .permanent
    case .unauthorized, .rateLimited, .temporarilyUnavailable:
      .transient
    case .configuration:
      .refused
    }
  }
}
