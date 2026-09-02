import Foundation
import QotaFolioCore

public nonisolated enum ProviderRegistry {
  public static func productionEnvironment(
    transport: any CancellableHTTPTransport,
    appVersion: String,
    now: @escaping @Sendable () -> Date,
    log: any RedactingLog,
    clock: any MonotonicClock = SystemMonotonicClock(),
    random: any RandomBytesGenerating = SystemRandomBytes(),
    browser: any BrowserOpening = WorkspaceBrowserOpener()
  ) -> ProviderEnvironment {
    ProviderEnvironment(
      transport: transport,
      appVersion: appVersion,
      now: now,
      clock: clock,
      random: random,
      browser: browser,
      log: log,
      makeAnthropicListener: { AnthropicLoopbackListener() }
    )
  }

  public static func suite(
    for provider: AccountProvider,
    environment: ProviderEnvironment
  ) -> ProviderSuite {
    switch provider {
    case .anthropic:
      AnthropicProviderSuite.make(environment: environment)
    case .openai:
      OpenAIProviderSuite.make(environment: environment)
    }
  }
}
