import Foundation

public nonisolated func remainingPercent(fromUsedPercent usedPercent: Double) -> Int? {
  guard usedPercent.isFinite, usedPercent >= 0 else { return nil }
  return Int(floor(min(100, max(0, 100 - usedPercent))))
}

public nonisolated func remainingSeverity(for remainingPercent: Int) -> UsageSeverity {
  switch remainingPercent {
  case 0:
    .critical
  case 1...20:
    .warning
  default:
    .normal
  }
}

public nonisolated func effectiveSeverity(
  providerSeverity: UsageSeverity?,
  remainingPercent: Int
) -> UsageSeverity {
  max(providerSeverity ?? .normal, remainingSeverity(for: remainingPercent))
}
