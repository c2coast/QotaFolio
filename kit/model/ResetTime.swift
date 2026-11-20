import Foundation

/// When a limit resets.
///
/// A provider names one reset a second apart from one answer to the next: the frozen record holds
/// 1764190799 for the week beside 1764190800 for Fable. So two reset times in the same minute are
/// one time. Equality and hashing go by the nearest minute, and every comparison of two reset times
/// gets that for free.
///
/// The instant as sent is kept, because the forecast's arithmetic uses it as the provider gave it.
public struct ResetTime: Hashable, Sendable {
    public let instant: Date

    public init(_ instant: Date) {
        self.instant = instant
    }

    /// Minutes since 1970, to the nearest minute.
    public var minute: Int64 {
        Int64((instant.timeIntervalSince1970 / 60).rounded(.toNearestOrEven))
    }

    public static func == (a: ResetTime, b: ResetTime) -> Bool { a.minute == b.minute }

    public func hash(into hasher: inout Hasher) { hasher.combine(minute) }
}
