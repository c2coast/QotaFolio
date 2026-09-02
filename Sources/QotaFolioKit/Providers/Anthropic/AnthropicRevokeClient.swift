import Foundation
import QotaFolioCore

/// Tells Anthropic that a grant QotaFolio minted is finished with.
///
/// `POST https://platform.claude.com/v1/oauth/token/revoke` is RFC 7009 public-client
/// revocation and is what `claude logout` calls. There is no `Authorization` header, no
/// cookie and no organization id: presenting the refresh token IS the authorisation, which
/// is why a public client can call it at all. (The other revoke path — the trash icon on
/// `claude.ai/settings` — needs a claude.ai session cookie and is not ours to call.)
///
/// Two properties this has, and they are the whole design:
///
/// **It only ever revokes a credential QotaFolio minted.** Every grant this app holds came
/// from its own PKCE flow and lives in its own Keychain item. Ending one on the user's
/// explicit Disconnect is the app doing its job. The rule this app keeps is "never revoke a
/// credential we did not mint", not "never revoke" — and it never reads another
/// application's credential store, so there is nothing else it could reach.
///
/// **It returns nothing, and it cannot fail.** Disconnect removes the credential from this
/// Mac whatever the network says, so a caller must not be able to make the local wipe
/// conditional on this call. There is no result to branch on and no error to catch. The
/// outcome goes to the diagnostic log, where it belongs.
public nonisolated struct AnthropicRevokeClient: GrantRevoking {
  public let provider: AccountProvider = .anthropic

  private let transport: any HTTPTransport
  private let clock: any MonotonicClock
  private let log: any RedactingLog

  public init(
    transport: any HTTPTransport,
    clock: any MonotonicClock,
    log: any RedactingLog
  ) {
    self.transport = transport
    self.clock = clock
    self.log = log
  }

  /// Best effort, bounded, and silent about its result.
  ///
  /// - Parameter refreshToken: the refresh token of a grant this app minted. The access
  ///   token is not accepted: revoking the refresh token ends the whole chain, which is what
  ///   Disconnect means.
  public func revoke(refreshToken: SecretString) async {
    guard !refreshToken.isEmpty else {
      emit(outcome: .refused, status: nil, durationMS: nil)
      return
    }
    guard let request = makeRequest(refreshToken: refreshToken) else {
      emit(outcome: .refused, status: nil, durationMS: nil)
      return
    }

    let started = clock.now
    do {
      let (_, http) = try await transport.send(
        request,
        maxResponseBytes: CREDENTIAL_POST_MAX_BYTES
      )
      // RFC 7009 says a server answers 200 for a token it revoked AND for one it never
      // issued, so a 200 is not proof of anything a user would notice. It is logged as what
      // it was and nothing turns on it.
      emit(
        outcome: (200..<300).contains(http.statusCode) ? .ok : .transient,
        status: http.statusCode,
        durationMS: clock.elapsedMS(since: started)
      )
    } catch {
      // Including cancellation. A quit or a Disconnect that races this call still removes
      // the credential locally; leaving a token alive at the provider is the lesser harm,
      // and the user can end it from claude.ai.
      emit(outcome: .transient, status: nil, durationMS: clock.elapsedMS(since: started))
    }
  }

  private func makeRequest(refreshToken: SecretString) -> URLRequest? {
    guard let url = URL(string: AnthropicWire.revokeURL) else { return nil }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = AnthropicWire.revokeTimeout
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    var body: Data?
    refreshToken.withUnsafeRawValue { token in
      body = try? JSONSerialization.data(
        withJSONObject: [
          "token": token,
          "token_type_hint": "refresh_token",
          "client_id": AnthropicWire.clientID,
        ],
        options: [.sortedKeys]
      )
    }
    guard let body else { return nil }
    request.httpBody = body
    return request
  }

  private func emit(outcome: DiagOutcome, status: Int?, durationMS: Int?) {
    log.emit(
      DiagEvent(
        provider: .anthropic,
        operation: .revoke,
        outcome: outcome,
        host: AnthropicWire.revokeHost,
        path: AnthropicWire.revokePath,
        httpStatus: status,
        durationMS: durationMS
      )
    )
  }
}
