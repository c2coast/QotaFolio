import Foundation
import QotaFolioCore

/// Asks Anthropic whose account a grant belongs to.
///
/// One GET, the same headers the usage request carries, and the answer normalised into
/// `ProviderAccountIdentity`. No cache, no schedule, no retry — the caller decides when to
/// ask, exactly as it does for usage.
///
/// This never reads another application's credentials. It presents the access token
/// QotaFolio's own PKCE flow minted, from QotaFolio's own Keychain item, and it presents
/// nothing else.
public nonisolated protocol ProviderIdentityFetching: Sendable {
  var provider: AccountProvider { get }
  func fetchIdentity(token: ValidAccessToken) async throws -> ProviderAccountIdentity
}

public nonisolated struct AnthropicProfileClient: ProviderIdentityFetching {
  public let provider: AccountProvider = .anthropic

  private let transport: any HTTPTransport
  private let appVersion: String
  private let now: @Sendable () -> Date
  private let clock: any MonotonicClock
  private let log: any RedactingLog

  public init(
    transport: any HTTPTransport,
    appVersion: String,
    now: @escaping @Sendable () -> Date,
    clock: any MonotonicClock,
    log: any RedactingLog
  ) {
    self.transport = transport
    self.appVersion = appVersion
    self.now = now
    self.clock = clock
    self.log = log
  }

  public func fetchIdentity(token: ValidAccessToken) async throws -> ProviderAccountIdentity {
    guard let request = makeRequest(token: token) else {
      emit(outcome: .refused, status: nil, durationMS: nil)
      throw UsageProviderError.configuration
    }

    try Task.checkCancellation()
    let started = clock.now

    let body: Data
    let http: HTTPURLResponse
    do {
      (body, http) = try await transport.send(
        request,
        maxResponseBytes: AnthropicWire.profileMaxResponseBytes
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as HTTPTransportError {
      try Task.checkCancellation()
      let failure = ProviderUsageErrorPolicy.mapTransportError(error)
      emit(outcome: outcome(for: failure), status: nil, durationMS: clock.elapsedMS(since: started))
      throw failure
    } catch {
      try Task.checkCancellation()
      emit(outcome: .transient, status: nil, durationMS: clock.elapsedMS(since: started))
      throw UsageProviderError.temporarilyUnavailable
    }

    try Task.checkCancellation()
    let durationMS = clock.elapsedMS(since: started)
    let retryAfter = RetryAfter.parse(http.value(forHTTPHeaderField: "Retry-After"), now: now())

    // The status decides whether there is a body worth reading at all. A 403, a 500 or a WAF
    // page is a request that failed; none of them is a statement about the grant, and none
    // of them may be read as one.
    switch ProviderUsageErrorPolicy.disposition(status: http.statusCode, retryAfter: retryAfter) {
    case .fail(let failure):
      emit(outcome: outcome(for: failure), status: http.statusCode, durationMS: durationMS)
      throw failure
    case .parseBody:
      do {
        let identity = try AnthropicProfileParser.parse(body)
        emit(outcome: .ok, status: http.statusCode, durationMS: durationMS)
        return identity
      } catch {
        emit(outcome: .permanent, status: http.statusCode, durationMS: durationMS)
        throw UsageProviderError.invalidPayload
      }
    }
  }

  private func makeRequest(token: ValidAccessToken) -> URLRequest? {
    guard case .anthropic(let accessToken, _) = token else { return nil }
    guard let userAgent = ProductUserAgent.value(appVersion: appVersion) else { return nil }
    guard let url = URL(string: AnthropicWire.profileURL) else { return nil }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(AnthropicWire.usageBetaHeader, forHTTPHeaderField: "anthropic-beta")
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    accessToken.withUnsafeRawValue {
      request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization")
    }
    return request
  }

  private func emit(outcome: DiagOutcome, status: Int?, durationMS: Int?) {
    log.emit(
      DiagEvent(
        provider: .anthropic,
        operation: .profileGET,
        outcome: outcome,
        host: AnthropicWire.profileHost,
        path: AnthropicWire.profilePath,
        httpStatus: status,
        durationMS: durationMS
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
