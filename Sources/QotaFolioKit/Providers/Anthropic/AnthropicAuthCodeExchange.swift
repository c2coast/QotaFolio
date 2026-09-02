import Foundation
import QotaFolioCore

nonisolated struct AnthropicAuthCodeExchange {
  let transport: any HTTPTransport
  let clock: any MonotonicClock
  let now: @Sendable () -> Date
  let log: any RedactingLog

  init(
    transport: any HTTPTransport,
    clock: any MonotonicClock,
    now: @escaping @Sendable () -> Date,
    log: any RedactingLog
  ) {
    self.transport = transport
    self.clock = clock
    self.now = now
    self.log = log
  }

  func exchange(
    code: SecretString,
    state: SecretString,
    verifier: SecretString,
    redirectURI: URL
  ) async throws -> OAuthTokenSet {
    let payload = TokenExchangePayload(
      grantType: "authorization_code",
      code: code,
      state: state,
      clientID: AnthropicWire.clientID,
      redirectURI: redirectURI.absoluteString,
      codeVerifier: verifier
    )
    guard let url = URL(string: AnthropicWire.tokenURL) else {
      throw OAuthLoginError.exchangeFailed
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(payload)

    try Task.checkCancellation()
    let started = clock.now

    do {
      let (body, response) = try await transport.send(
        request,
        maxResponseBytes: CREDENTIAL_POST_MAX_BYTES
      )
      try Task.checkCancellation()

      let durationMS = clock.elapsedMS(since: started)
      let sizeBucket = diagnosticSizeBucket(forByteCount: body.count)
      guard (200...299).contains(response.statusCode) else {
        log.emit(
          event(
            outcome: .permanent,
            status: response.statusCode,
            durationMS: durationMS,
            sizeBucket: sizeBucket
          )
        )
        throw OAuthLoginError.exchangeFailed
      }

      guard let tokens = AnthropicLoginTokenDecoder.decodeLoginTokens(
        body: body,
        receivedAt: now()
      ) else {
        log.emit(
          event(
            outcome: .permanent,
            status: response.statusCode,
            durationMS: durationMS,
            sizeBucket: sizeBucket
          )
        )
        throw OAuthLoginError.exchangeFailed
      }

      // The server states what it granted, and it may grant less than was asked for. Without
      // `user:profile` the usage endpoint returns nothing usable, so this grant can never
      // show a number — say so now, while the user is still here, instead of handing them an
      // account that sits empty forever.
      let missing = AnthropicGrantedScope.missing(
        fromTokenResponse: body,
        requested: AnthropicWire.scope
      )
      guard missing.isEmpty else {
        log.emit(
          event(
            outcome: .permanent,
            status: response.statusCode,
            durationMS: durationMS,
            sizeBucket: sizeBucket
          )
        )
        throw OAuthLoginError.scopeNotGranted
      }

      log.emit(
        event(
          outcome: .ok,
          status: response.statusCode,
          durationMS: durationMS,
          sizeBucket: sizeBucket
        )
      )
      return tokens
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as HTTPTransportError {
      try Task.checkCancellation()
      log.emit(
        event(
          outcome: .transient,
          status: nil,
          durationMS: clock.elapsedMS(since: started),
          sizeBucket: nil
        )
      )
      _ = error
      throw OAuthLoginError.exchangeFailed
    } catch let error as OAuthLoginError {
      throw error
    } catch {
      try Task.checkCancellation()
      log.emit(
        event(
          outcome: .transient,
          status: nil,
          durationMS: clock.elapsedMS(since: started),
          sizeBucket: nil
        )
      )
      throw OAuthLoginError.exchangeFailed
    }
  }

  private func event(
    outcome: DiagOutcome,
    status: Int?,
    durationMS: Int,
    sizeBucket: Int?
  ) -> DiagEvent {
    DiagEvent(
      provider: .anthropic,
      operation: .exchange,
      outcome: outcome,
      host: AnthropicWire.tokenHost,
      path: AnthropicWire.tokenPath,
      httpStatus: status,
      durationMS: durationMS,
      sizeBucket: sizeBucket
    )
  }
}

// This struct holds a COMPLETE Anthropic grant — the authorization
// code, the CSRF state and the PKCE verifier together. PKCE protects nothing once code and verifier travel in one
// value. All three are the carrier type; synthesised Encodable writes the same three JSON strings.
nonisolated struct TokenExchangePayload: Encodable, Sendable {   // module-internal, not file-private: the redaction suite executes the four printing paths against a populated instance of this type
  let grantType: String
  let code: SecretString
  let state: SecretString
  let clientID: String
  let redirectURI: String
  let codeVerifier: SecretString

  private enum CodingKeys: String, CodingKey {
    case grantType = "grant_type"
    case code
    case state
    case clientID = "client_id"
    case redirectURI = "redirect_uri"
    case codeVerifier = "code_verifier"
  }
}
