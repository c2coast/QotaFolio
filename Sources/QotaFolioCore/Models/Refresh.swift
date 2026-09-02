import Foundation

public nonisolated enum OAuthRefreshRoute: Sendable {   // vault-owned; the ONLY egress the vault will ever send a refresh token to
  case anthropic; case openAI
  public var provider: AccountProvider { switch self { case .anthropic: .anthropic; case .openAI: .openai } } }

public nonisolated enum RefreshLineageFailure: Sendable { case anthropicInvalidGrant; case openAIInvalidGrant; case openAIRefreshTokenExpired; case openAIRefreshTokenInvalidated; case openAIRefreshTokenReused }

public nonisolated enum TokenRefreshError: Error, Sendable { case permanent(RefreshLineageFailure); case transient }

public nonisolated enum OAuthTokenRefreshDelta: Sendable, CustomStringConvertible {   // ONLY values the successful server response carried; optional ⇒ omitted/null (NOT "already merged")
  case anthropic(accessToken: SecretString, refreshToken: SecretString, expiresIn: TimeInterval)
  case openai(accessToken: SecretString, refreshToken: SecretString?, chatGPTAccountIDFromIDToken: SecretString?, accessExpiresAt: Date?)
  public var description: String { "<redacted OAuthTokenRefreshDelta>" } }

public nonisolated protocol ProviderRefreshResponseDecoder: Sendable {   // the provider's REFRESH half — PURE response parsing/classification only
  var provider: AccountProvider { get }
  func decodeRefreshResponse(status: Int, body: Data) throws -> OAuthTokenRefreshDelta  // NEVER receives current credentials; throw TokenRefreshError
}
