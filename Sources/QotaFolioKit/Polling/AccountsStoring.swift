import Foundation
import Observation
import QotaFolioCore

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
  /// Each account's readings, the newest poll last, as the history reads them from its books
  /// after every recorded poll. Empty until the books are first read.
  ///
  /// A view says an account at a moment by building `AccountNow(readings:words:)` from them
  /// with the panel's own time, because the words depend on the moment: "today", a reset that
  /// has passed.
  var readings: AccountReadings { get }
  func start()
  func stop()
  func reconcile(accounts: [AccountConfig], reauthenticated: [AccountID: CredentialRevision])
  func setPanelVisible(_ visible: Bool)
  func requestRefreshAll()                 // the panel footer's Refresh — the manual cohort
  func requestRefresh(_ id: AccountID) }
