import Foundation

public nonisolated struct ParsedUsage: Sendable {
  public let snapshot: UsageSnapshot
  public let schemaFamily: StaticString

  public init(snapshot: UsageSnapshot, schemaFamily: StaticString) {
    self.snapshot = snapshot
    self.schemaFamily = schemaFamily
  }
}
