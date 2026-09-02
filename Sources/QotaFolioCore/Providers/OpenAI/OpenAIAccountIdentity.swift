import CryptoKit
import Foundation

/// The identity of a ChatGPT account, from the grant the app just minted.
///
/// ChatGPT needs no profile request: the `chatgpt_account_id` claim in the ID token already
/// says whose account the grant is, and `OpenAIIDTokenDecoder` already reads it.
///
/// **What is written down is a digest of that claim, not the claim.** This app treats the
/// ChatGPT account id as credential-adjacent — it lives in the Keychain beside the tokens,
/// it travels in a `SecretString`, and it is sent as the `ChatGPT-Account-Id` header. Identity
/// needs equality and nothing else, and a digest gives equality without copying a value out
/// of the Keychain and into a plain file. The digest is unsalted so that it is the same on
/// every launch and on every machine; there is no secret to protect in a value the provider
/// puts in a header, only a decision not to spread it around.
public nonisolated enum OpenAIAccountIdentity {
  public static func make(chatGPTAccountID: SecretString) -> ProviderAccountIdentity? {
    var digest: String?
    chatGPTAccountID.withUnsafeRawValue { raw in
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      digest = "sha256:" + SHA256.hash(data: Data(trimmed.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    }
    guard let digest else { return nil }
    return ProviderAccountIdentity(
      accountKey: digest,
      organizationKey: nil,
      emailAddress: nil
    )
  }
}
