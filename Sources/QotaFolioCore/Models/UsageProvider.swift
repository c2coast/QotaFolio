import Foundation

// The provider seam. `UsageProvider` names a live network call, so it is bound to
// `ValidAccessToken` and stays in Core with it — nothing that only reads this app's files
// has a use for it. Every value type the call produces lives in `QotaFolioModel`, which is
// why a widget or the `qota` command can decode a snapshot without linking any of this.

public nonisolated enum UsageProviderError: Error, Sendable { case unauthorized; case rateLimited(retryAfter: Duration?); case temporarilyUnavailable; case invalidPayload; case configuration }

public nonisolated protocol UsageProvider: Sendable {
  var provider: AccountProvider { get }
  func fetchUsage(token: ValidAccessToken) async throws -> UsageSnapshot   // ONE GET + normalize. No cache/schedule/refresh/retry/persist here.
}
