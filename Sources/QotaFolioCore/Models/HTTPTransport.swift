import Foundation

public nonisolated enum HTTPTransportError: Error, Sendable {
  case responseTooLarge(limit: Int)          // body exceeded maxResponseBytes — FAIL DURING READ, never buffer past the cap
  case redirectNotFollowed(status: Int)      // ANY 3xx on a credentialed request (RF-6): 301/302/303/307/308 all hard-fail
                                             // On a USAGE GET this maps to UsageProviderError.temporarilyUnavailable — the no-redirect rule makes it a hard
                                             // failure of THAT request, but to the poller it is transient (a CDN/WAF edge answering 3xx recovers), so it is a
                                             // bounded retry, never .configuration and never a suspend. On the REFRESH POST it stays TokenRefreshError.transient.
  case transport(underlying: URLError)       // connection/TLS/timeout
  case invalidResponse }

public nonisolated protocol HTTPTransport: Sendable {   // ONE production impl (composition root, redirect-denying ephemeral URLSession); fakes in tests
  func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> (Data, HTTPURLResponse) }

public nonisolated let CREDENTIAL_POST_MAX_BYTES: Int = 64 * 1024

public nonisolated let TERMINATION_DRAIN_TIMEOUT: Duration = .seconds(2)
