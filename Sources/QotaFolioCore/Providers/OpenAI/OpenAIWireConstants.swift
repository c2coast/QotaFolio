import Foundation

public nonisolated enum OpenAIWire {
    public static let usageMaxResponseBytes: Int = 256 * 1024

    // A window is classified by how long it runs for, never by the slot it arrived in.
    // OpenAI moves the surviving window into the primary slot when it switches a limit off,
    // so slot position tells you nothing about which window you are holding. Both bands are
    // the nominal length plus or minus five percent.
    /// A window length outside this range is not a rate-limit window, whatever the field
    /// says. The endpoint publishes no schema, so a number arriving here has been checked by
    /// nobody; one second to a year is generous and everything beyond it is a malformed
    /// field rather than a limit anyone is spending against.
    public static let plausibleWindowSecondsRange: ClosedRange<Double> = 1...31_622_400
    public static let sessionWindowSecondsRange: ClosedRange<Double> = 17_100...18_900
    public static let weeklyWindowSecondsRange: ClosedRange<Double> = 574_560...635_040

    /// One flex credit, in dollars. The Codex CLI prices credits at this rate and floors the
    /// count first, so the app prints the figure the CLI prints.
    public static let creditDollarRate: Double = 0.04

    public static let usageHost: StaticString = "chatgpt.com"
    public static let usagePath: StaticString = "/backend-api/wham/usage"
    public static let authHost: StaticString = "auth.openai.com"
    public static let deviceUsercodePath: StaticString = "/api/accounts/deviceauth/usercode"
    public static let devicePollPath: StaticString = "/api/accounts/deviceauth/token"
    public static let tokenPath: StaticString = "/oauth/token"

    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let deviceUsercodeURL = "https://auth.openai.com/api/accounts/deviceauth/usercode"
    public static let verificationURL = "https://auth.openai.com/codex/device"
    public static let devicePollURL = "https://auth.openai.com/api/accounts/deviceauth/token"
    public static let tokenURL = "https://auth.openai.com/oauth/token"
    public static let exchangeRedirectURI = "https://auth.openai.com/deviceauth/callback"
    public static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    public static let claimNamespace = "https://api.openai.com/auth"
    public static let accountIDClaim = "chatgpt_account_id"

    public static let deviceDeadline: Duration = .seconds(900)
    public static let slowDownWidening: Duration = .seconds(5)
}
