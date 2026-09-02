import Foundation

// The Anthropic token endpoint's response body. Synthesised
// Decodable reads the two JSON strings directly — SecretString decodes through a single value container.
nonisolated struct AnthropicTokenResponseDTO: Decodable, Sendable {
  let accessToken: SecretString?
  let refreshToken: SecretString?
  let expiresIn: Double?
  /// What the server actually granted, which may be less than was asked for.
  let scope: String?

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresIn = "expires_in"
    case scope
  }
}

/// What the server granted, checked against what was asked for.
///
/// An OAuth server may grant less than a client requests and say so only in the `scope`
/// field of the token response. QotaFolio asks for exactly `user:profile`, and without it
/// `/api/oauth/usage` returns nothing usable — so a grant that is short is one that can never
/// show a number. Discovering that at the next usage fetch means a new account that sits
/// there empty and a user with no idea why; discovering it here means saying so while they
/// are still standing at the sign-in.
public nonisolated enum AnthropicGrantedScope {
  /// The requested scopes the server did not grant.
  ///
  /// An empty result means the grant is sufficient. A response that names no scope at all is
  /// treated as sufficient: RFC 6749 makes `scope` optional exactly when the grant matches
  /// the request, and refusing a silent server would refuse every grant it ever issued.
  public static func missing(fromTokenResponse body: Data, requested: String) -> [String] {
    let requestedScopes = scopes(in: requested)
    guard !requestedScopes.isEmpty else { return [] }

    guard
      let granted = (try? JSONDecoder().decode(AnthropicTokenResponseDTO.self, from: body))?.scope,
      !granted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return []
    }

    let grantedScopes = Set(scopes(in: granted))
    return requestedScopes.filter { !grantedScopes.contains($0) }
  }

  private static func scopes(in value: String) -> [String] {
    value
      .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "," })
      .map(String.init)
      .filter { !$0.isEmpty }
  }
}

public nonisolated enum AnthropicLoginTokenDecoder {
  public static func decodeLoginTokens(body: Data, receivedAt: Date) -> OAuthTokenSet? {
    guard let response = try? JSONDecoder().decode(AnthropicTokenResponseDTO.self, from: body) else {
      return nil
    }
    guard
      let accessToken = nonEmpty(response.accessToken),
      let refreshToken = nonEmpty(response.refreshToken),
      let expiresIn = response.expiresIn,
      expiresIn.isFinite,
      expiresIn > 0
    else {
      return nil
    }

    let expiresAt = receivedAt.addingTimeInterval(expiresIn)
    guard expiresAt.timeIntervalSince1970.isFinite else { return nil }
    return .anthropic(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt
    )
  }

  private static func nonEmpty(_ value: SecretString?) -> SecretString? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}
