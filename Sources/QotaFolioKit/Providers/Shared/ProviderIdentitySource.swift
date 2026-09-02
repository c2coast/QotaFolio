import Foundation
import QotaFolioCore

/// The one place the add flow asks "whose account is this grant?".
///
/// Both providers answer through `ProviderIdentityFetching`, so the caller writes one line
/// and no provider branch. Anthropic costs a GET to `/api/oauth/profile`; ChatGPT costs
/// nothing, because its grant already carries the answer.
///
/// This is deliberately not a member of `ProviderSuite`. The suite is constructed in four
/// places across three targets, and an identity fetcher is needed at exactly one moment in
/// one flow — a factory keeps that need where it is used.
public nonisolated enum ProviderIdentitySource {
  public static func make(
    provider: AccountProvider,
    environment: ProviderEnvironment
  ) -> any ProviderIdentityFetching {
    switch provider {
    case .anthropic:
      AnthropicProfileClient(
        transport: environment.transport,
        appVersion: environment.appVersion,
        now: environment.now,
        clock: environment.clock,
        log: environment.log
      )
    case .openai:
      OpenAITokenIdentity()
    }
  }
}
