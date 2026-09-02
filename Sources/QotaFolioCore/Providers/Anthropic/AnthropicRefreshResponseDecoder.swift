import Foundation

public nonisolated struct AnthropicRefreshResponseDecoder: ProviderRefreshResponseDecoder {
  public let provider: AccountProvider = .anthropic

  public init() {}

  public func decodeRefreshResponse(status: Int, body: Data) throws -> OAuthTokenRefreshDelta {
    guard (200...299).contains(status) else {
      if AnthropicOAuthErrorCode.decode(from: body) == .invalidGrant {
        throw TokenRefreshError.permanent(.anthropicInvalidGrant)
      }
      throw TokenRefreshError.transient
    }

    guard let response = try? JSONDecoder().decode(AnthropicTokenResponseDTO.self, from: body) else {
      throw TokenRefreshError.transient
    }
    guard
      let accessToken = Self.nonEmpty(response.accessToken),
      let refreshToken = Self.nonEmpty(response.refreshToken),
      let expiresIn = response.expiresIn,
      expiresIn.isFinite,
      expiresIn > 0
    else {
      throw TokenRefreshError.transient
    }

    return .anthropic(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresIn: expiresIn
    )
  }

  private static func nonEmpty(_ value: SecretString?) -> SecretString? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}
