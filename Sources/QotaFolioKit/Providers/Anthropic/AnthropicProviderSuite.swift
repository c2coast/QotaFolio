import QotaFolioCore

public nonisolated enum AnthropicProviderSuite {
  public static func make(environment: ProviderEnvironment) -> ProviderSuite {
    ProviderSuite(
      provider: .anthropic,
      usage: AnthropicProductionUsageProvider(
        transport: environment.transport,
        appVersion: environment.appVersion,
        now: environment.now,
        clock: environment.clock,
        log: environment.log
      ),
      refreshDecoder: AnthropicRefreshResponseDecoder(),
      acquirerFactory: {
        AnthropicOAuthAcquirer(
          transport: environment.transport,
          makeListener: environment.makeAnthropicListener,
          browser: environment.browser,
          random: environment.random,
          clock: environment.clock,
          now: environment.now,
          log: environment.log
        )
      }
    )
  }
}
