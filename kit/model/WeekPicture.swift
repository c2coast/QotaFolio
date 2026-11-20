import Foundation

/// One account's week as the graph draws it and the sentences speak of it, at one poll: the week's
/// bounds, its polls up to that one, what the record shows between them, and the forecast.
///
/// It holds no drawing: no pixels, colours, axis or label places. Every graph of the week reads
/// the same picture.
public struct WeekPicture: Sendable {
    public let account: AccountID
    /// The model's week the account has, such as Fable's. None for an account with only the week.
    public let model: Limit.Kind?
    /// The week's start, a week before its reset, and the reset in force. A reset is known to the
    /// minute, so when the poll in force came a moment before that start, the week starts at it.
    public let start: Date
    public let resets: ResetTime
    /// This week's points up to the poll in force, in time order. The last is the poll in force:
    /// the readings now.
    ///
    /// When the history began before this week and the week's first poll came more than a minute
    /// after its start, the first point is the week opening at zero, by the provider's rule.
    public let points: [Point]
    /// The lead-in nobody recorded: from the week's start to its first poll, when the history
    /// itself began inside this week and more than a minute after the start.
    public let unrecorded: DateInterval?
    /// The falls of this week up to now, in time order.
    public let falls: [Fall]
    /// Every stretch of more than `gapSeconds` between two points, in time order.
    public let gaps: [Gap]
    /// Every stretch with the week at 100 percent, from a point at 100 to the next point, or to
    /// now. Stretches that touch are one.
    public let atLimit: [DateInterval]
    /// The verdict for the week and for the model's week, as the Engine gave them at this poll.
    public let verdicts: [Limit.Kind: Verdict]
    /// What the account will meet first.
    public let forecast: AccountForecast

    public init(account: AccountID, model: Limit.Kind?, start: Date, resets: ResetTime, points: [Point],
                unrecorded: DateInterval?, falls: [Fall], gaps: [Gap], atLimit: [DateInterval],
                verdicts: [Limit.Kind: Verdict], forecast: AccountForecast) {
        precondition(!points.isEmpty, "a week picture holds at least the poll in force")
        self.account = account
        self.model = model
        self.start = start
        self.resets = resets
        self.points = points
        self.unrecorded = unrecorded
        self.falls = falls
        self.gaps = gaps
        self.atLimit = atLimit
        self.verdicts = verdicts
        self.forecast = forecast
    }

    /// The poll in force: the readings now.
    public var now: Point { points[points.count - 1] }

    /// The week is at 100 percent.
    public var spent: Bool { now.week.used >= 100 }

    /// The model's week is at 100 percent.
    public var modelSpent: Bool { (now.model?.used ?? 0) >= 100 }

    /// One point of the week: a poll, or the week opening at zero.
    public struct Point: Hashable, Sendable {
        public let at: Date
        public let week: Meter
        /// None for an account with only the week.
        public let model: Meter?
        /// False for the week opening at zero, which no poll read.
        public let polled: Bool

        public init(at: Date, week: Meter, model: Meter?, polled: Bool) {
            self.at = at
            self.week = week
            self.model = model
            self.polled = polled
        }
    }

    /// One meter at one point: the percent it read, and the points falls gave back so far this week.
    public struct Meter: Hashable, Sendable {
        public let used: Double
        public let givenBack: Double

        public init(used: Double, givenBack: Double) {
            self.used = used
            self.givenBack = givenBack
        }

        /// The work done this week: the reading plus the points given back. It never falls inside
        /// a week, where the reading falls at every banked reset.
        public var work: Double { used + givenBack }
    }

    /// Polls further apart than this, two hours, leave a gap in the record.
    public static let gapSeconds: TimeInterval = 2 * 3600

    /// A stretch of more than two hours with no poll. When a fall ended on its last poll, the fall
    /// happened somewhere inside it.
    public struct Gap: Hashable, Sendable {
        public let before: Point
        public let after: Point
        public let fall: Fall?

        public init(before: Point, after: Point, fall: Fall?) {
            self.before = before
            self.after = after
            self.fall = fall
        }
    }
}
