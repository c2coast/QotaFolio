import Foundation
import Observation

@MainActor public protocol AccountsStoring: AnyObject, Observable {
  var snapshots: [AccountID: UsageSnapshot] { get }
  var pollStatus: [AccountID: AccountPollStatus] { get }
  var isPanelVisible: Bool { get }
  var manualRefresh: ManualRefreshActivity? { get }
  /// Whether quota updates are still running for this run of the app.
  ///
  /// Observed, because the panel renders it. The engine can close itself permanently, and every
  /// surface that offers a refresh — the footer button, the status menu's Refresh Now, the card —
  /// has to read that fact instead of calling into a store that returns without doing anything.
  var usageUpdates: UsageUpdatesState { get }
  /// What the brain decided, the last time it looked. `nil` before the first poll.
  ///
  /// Observed, because the panel's instrument draws the projection from it. A store that had
  /// this and did not publish it would leave the panel redrawing on snapshots alone, which
  /// change on a poll where a verdict can change on a countdown.
  var assessment: FleetAssessment? { get }
  /// One account's samples and completed windows — what the panel's instrument draws when a
  /// card is opened. `nil` when the app keeps no history for the account.
  ///
  /// `async` because the history flushes before it answers, off the main actor. The card asks
  /// on open and holds the one trace it is drawing; nothing holds the book.
  func trace(for account: AccountID) async -> AccountUsageTrace?
  func start()
  func stop()
  func reconcile(accounts: [AccountConfig], reauthenticated: [AccountID: CredentialRevision])
  func setPanelVisible(_ visible: Bool)
  func requestRefreshAll()                 // the panel footer's Refresh — the manual cohort
  func requestRefresh(_ id: AccountID) }

public nonisolated enum ManualRefreshActivity: Equatable, Sendable {   // `id` is monotonic, so the panel can announce "Usage updated" exactly once per cohort
  case inProgress(id: UInt64, total: Int)   // total = cohort size (accounts in the user-requested refresh). `id` is UInt64 to match the engine's own monotonic counter, which is what mints it.
  case completed(id: UInt64, at: Date) }
