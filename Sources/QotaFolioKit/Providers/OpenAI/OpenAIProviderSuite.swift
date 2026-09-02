import QotaFolioCore

public nonisolated enum OpenAIProviderSuite {
    public static func make(environment: ProviderEnvironment) -> ProviderSuite {
        ProviderSuite(
            provider: .openai,
            usage: OpenAIProductionUsageProvider(
                transport: environment.transport,
                now: environment.now,
                clock: environment.clock,
                log: environment.log
            ),
            refreshDecoder: OpenAIRefreshResponseDecoder(),
            acquirerFactory: {
                OpenAIOAuthAcquirer(
                    transport: environment.transport,
                    browser: environment.browser,
                    clock: environment.clock,
                    now: environment.now,
                    log: environment.log
                )
            }
        )
    }
}
