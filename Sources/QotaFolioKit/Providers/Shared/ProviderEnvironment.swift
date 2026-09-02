import Foundation
import QotaFolioCore

public nonisolated struct ProviderEnvironment: Sendable {
  public let transport: AnyCancellableHTTPTransport
  public let appVersion: String
  public let now: @Sendable () -> Date
  public let clock: any MonotonicClock
  public let random: any RandomBytesGenerating
  public let browser: any BrowserOpening
  public let log: any RedactingLog
  public let makeAnthropicListener: @Sendable () -> any AnthropicCallbackListening

  public init(
    transport: any CancellableHTTPTransport,
    appVersion: String,
    now: @escaping @Sendable () -> Date,
    clock: any MonotonicClock,
    random: any RandomBytesGenerating,
    browser: any BrowserOpening,
    log: any RedactingLog,
    makeAnthropicListener: @escaping @Sendable () -> any AnthropicCallbackListening
  ) {
    self.transport = AnyCancellableHTTPTransport(transport)
    self.appVersion = appVersion
    self.now = now
    self.clock = clock
    self.random = random
    self.browser = browser
    self.log = log
    self.makeAnthropicListener = makeAnthropicListener
  }
}
