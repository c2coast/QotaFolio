import Foundation

/// One limit of an account at one reading: which limit it is, how much is used, and when it resets.
public struct Limit: Hashable, Sendable {
    public let kind: Kind
    public let used: Percent
    /// Absent when the provider named no reset.
    public let resets: ResetTime?

    public init(kind: Kind, used: Percent, resets: ResetTime?) {
        self.kind = kind
        self.used = used
        self.resets = resets
    }

    /// Which limit: the models it counts, and how long it runs. The same kind at two readings is
    /// the same limit.
    public struct Kind: Hashable, Sendable {
        /// Absent for a limit on every model; the model's name for a limit on one model.
        public let model: String?
        public let period: Period

        public init(model: String?, period: Period) {
            self.model = model
            self.period = period
        }

        /// The account's week, over every model.
        public static let week = Kind(model: nil, period: .week)

        /// One model's own week, such as Fable's.
        public static func modelWeek(_ model: String) -> Kind {
            Kind(model: model, period: .week)
        }
    }

    /// How long a limit runs before it resets. A provider can name any length, and the length
    /// is kept as sent.
    public enum Period: Hashable, Sendable {
        case week
        case session
        case other(seconds: Double)
    }
}
