import Foundation

public nonisolated enum AnthropicWire {
  public static let usageMaxResponseBytes: Int = 256 * 1024
  public static let usageHost: StaticString = "api.anthropic.com"
  public static let usagePath: StaticString = "/api/oauth/usage"
  public static let tokenHost: StaticString = "platform.claude.com"
  public static let tokenPath: StaticString = "/v1/oauth/token"
  public static let revokeHost: StaticString = "platform.claude.com"
  public static let revokePath: StaticString = "/v1/oauth/token/revoke"
  public static let revokeURL = "https://platform.claude.com/v1/oauth/token/revoke"
  /// A revoke that has not answered by now is one the app stops waiting for. Disconnect
  /// removes the credential from this Mac either way, so nothing is gained by making the
  /// user watch a slow network.
  public static let revokeTimeout: TimeInterval = 5

  public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  public static let authorizeURL = "https://claude.ai/oauth/authorize"
  public static let tokenURL = "https://platform.claude.com/v1/oauth/token"
  public static let usageURL = "https://api.anthropic.com/api/oauth/usage"
  public static let profileHost: StaticString = "api.anthropic.com"
  public static let profilePath: StaticString = "/api/oauth/profile"
  public static let profileURL = "https://api.anthropic.com/api/oauth/profile"
  public static let profileMaxResponseBytes: Int = 16 * 1024
  public static let scope = "user:profile"

  /// Forces Anthropic to ask which account is being granted.
  ///
  /// Without it the browser's existing session decides silently, so a user adding their
  /// second account gets a second grant on their first one and the app shows the same
  /// numbers twice under two names.
  public static let authorizePrompt = "login"
  public static let usageBetaHeader = "oauth-2025-04-20"

  /// Anthropic's own first-party header for a client to name itself, in `name/version`
  /// shape. QotaFolio says who it is rather than pretending to be Claude Code — the usage
  /// endpoint does not gate on the User-Agent, so the spoof every other client sends buys
  /// nothing and costs the truth.
  public static let clientAppHeaderName = "x-client-app"
  public static let redirectURITemplate = "http://localhost:%d/callback"
  public static let loginDeadline: Duration = .seconds(600)
  public static let callbackRequestMaxBytes: Int = 16 * 1024
}
