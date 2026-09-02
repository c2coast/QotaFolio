import Foundation
import QotaFolioCore

/// Answers whose ChatGPT account a grant is, from the grant itself.
///
/// ChatGPT needs no profile request: the `chatgpt_account_id` claim in the ID token already
/// names the account, and the vault has been carrying it since the grant was minted. So this
/// satisfies the same protocol as the Anthropic client and makes no request at all — the add
/// flow asks both providers the same question in the same line, and only one of them costs a
/// round trip.
public nonisolated struct OpenAITokenIdentity: ProviderIdentityFetching {
  public let provider: AccountProvider = .openai

  public init() {}

  public func fetchIdentity(token: ValidAccessToken) async throws -> ProviderAccountIdentity {
    guard case .openai(_, let accountID, _) = token else {
      throw UsageProviderError.configuration
    }
    guard let identity = OpenAIAccountIdentity.make(chatGPTAccountID: accountID) else {
      throw UsageProviderError.invalidPayload
    }
    return identity
  }
}
