import Foundation

/// What the Engine works out for one account: the verdict for each limit at every poll, the falls,
/// and the points the falls gave back. Derived each time from the readings, and never stored.
///
/// The verdict at a poll reads only that poll and the ones before it, so the forecast at any
/// moment is the poll in force then: `poll(at:)`.
public struct Forecast: Sendable {
    /// One for each reading the Engine could place in a week, in time order.
    public let polls: [Poll]
    /// Every banked reset found between two polls of one week, in time order.
    public let falls: [Fall]

    public init(polls: [Poll], falls: [Fall]) {
        self.polls = polls
        self.falls = falls
    }

    /// The latest poll at or before the moment, or none before the first poll.
    public func poll(at moment: Date) -> Poll? {
        polls.last { $0.reading.at <= moment }
    }

    /// The model's week the polls give a verdict for, such as Fable's. None for an account with only
    /// the week.
    public var model: Limit.Kind? {
        polls.lazy.flatMap(\.verdicts.keys).first { $0 != .week }
    }

    public struct Poll: Sendable {
        public let reading: Reading
        /// The week's reset in force at this poll. The model's week resets with it, so its own
        /// reset time is never read.
        public let resets: ResetTime
        /// What each limit with a verdict reads at this poll. The model's week, when this poll did
        /// not read it, reads as its latest reading of the week.
        public let used: [Limit.Kind: Percent]
        /// A verdict for the week and for the model's week. A limit of any other period has none yet.
        public let verdicts: [Limit.Kind: Verdict]
        /// The points falls gave back so far this week, for each limit with a verdict.
        public let givenBack: [Limit.Kind: Double]

        public init(reading: Reading, resets: ResetTime, used: [Limit.Kind: Percent], verdicts: [Limit.Kind: Verdict],
                    givenBack: [Limit.Kind: Double]) {
            self.reading = reading
            self.resets = resets
            self.used = used
            self.verdicts = verdicts
            self.givenBack = givenBack
        }
    }
}
