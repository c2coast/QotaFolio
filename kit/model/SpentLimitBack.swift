import Foundation

/// That a limit which had reached 100 percent is back: the condition of the alert "a spent limit
/// is back". Between two consecutive readings of one account the limit read 100, then less, or
/// its reset passed.
///
/// It is the account, the limit, the reset of the occurrence it was spent in, and how it came
/// back, so one event is one value however often it is worked out, and two events are two: a
/// week that a banked reset brings back, spent again, and back at its reset.
public struct SpentLimitBack: Hashable, Sendable {
    public let account: AccountID
    public let limit: Limit.Kind
    /// The reset of the occurrence the limit was spent in.
    public let spentUntil: ResetTime
    public let how: How

    public init(account: AccountID, limit: Limit.Kind, spentUntil: ResetTime, how: How) {
        (self.account, self.limit, self.spentUntil, self.how) = (account, limit, spentUntil, how)
    }

    public enum How: Hashable, Sendable {
        /// Its reset came.
        case reset
        /// A banked reset gave its points back before its reset came.
        case banked
    }
}
