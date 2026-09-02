import QotaFolioCore

public nonisolated struct ProviderSuite: Sendable {
  public let provider: AccountProvider
  public let usage: any ProductionUsageProvider
  public let refreshDecoder: any ProviderRefreshResponseDecoder
  private let acquirerFactory: @Sendable () -> any OAuthTokenAcquirer

  public init(
    provider: AccountProvider,
    usage: any ProductionUsageProvider,
    refreshDecoder: any ProviderRefreshResponseDecoder,
    acquirerFactory: @escaping @Sendable () -> any OAuthTokenAcquirer
  ) {
    self.provider = provider
    self.usage = usage
    self.refreshDecoder = refreshDecoder
    self.acquirerFactory = acquirerFactory
  }

  public func makeAcquirer() -> any OAuthTokenAcquirer {
    acquirerFactory()
  }
}
