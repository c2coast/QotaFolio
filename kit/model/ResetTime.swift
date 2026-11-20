import Foundation

/// When a limit resets, on the minute.
///
/// A provider names one reset a second apart from one answer to the next: the frozen record holds
/// 1764190799 for the week beside 1764190800 for Fable. A reset is a minute, so a reset time is
/// made on the nearest minute, and two reset times are the same when they are equal.
public struct ResetTime: Hashable, Sendable {
    public let instant: Date

    /// The nearest minute to the instant a provider sent.
    public init(_ sent: Date) {
        instant = Date(timeIntervalSince1970: (sent.timeIntervalSince1970 / 60).rounded(.toNearestOrEven) * 60)
    }
}
