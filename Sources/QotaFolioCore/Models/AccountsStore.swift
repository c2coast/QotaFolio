import Foundation

public nonisolated enum ManualRefreshActivity: Equatable, Sendable {   // `id` is monotonic, so the panel can announce "Usage updated" exactly once per cohort
  case inProgress(id: UInt64, total: Int)   // total = cohort size (accounts in the user-requested refresh). `id` is UInt64 to match the engine's own monotonic counter, which is what mints it.
  case completed(id: UInt64, at: Date) }
