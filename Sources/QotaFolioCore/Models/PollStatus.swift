import Foundation

public nonisolated enum PollStaleReason: Equatable, Sendable {
  case rateLimited(retryAt: Date?)
  case temporarilyUnavailable
  case invalidPayload
  case authorizationRejectedAfterRefresh
  case storageTemporarilyUnavailable
  case credentialUnreadable            // corrupt / unknown Keychain envelope — distinct from AccountPollPhase.configurationFailure, which is a genuine persistent misconfiguration
}

public nonisolated enum AccountPollPhase: Equatable, Sendable {
  case waitingForFirstSnapshot
  case current
  case stale(PollStaleReason)
  case suspendedForReauthentication
  case configurationFailure
}

public nonisolated struct AccountPollStatus: Equatable, Sendable {
  public let phase: AccountPollPhase
  public let isRefreshing: Bool
  public let lastAttemptAt: Date?
  public let lastSuccessAt: Date?
  public let nextAttemptAt: Date?
  // COMPILER-PROVEN: with no declared init this struct could not be constructed by its SOLE WRITER, the polling engine in QotaFolioKit —
  // the synthesized memberwise init of a public struct is internal. Publish by whole-value replacement built with this init
  // (`pollStatus[id] = AccountPollStatus(...)`), never in-place field mutation of `let` members.
  public init(phase: AccountPollPhase, isRefreshing: Bool, lastAttemptAt: Date?, lastSuccessAt: Date?, nextAttemptAt: Date?) {
    self.phase = phase; self.isRefreshing = isRefreshing; self.lastAttemptAt = lastAttemptAt; self.lastSuccessAt = lastSuccessAt; self.nextAttemptAt = nextAttemptAt }
}
