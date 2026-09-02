import Foundation

/// One inter-sample interval of one window, classified.
///
/// Three facts about a stretch of wall time, and every estimator downstream reads some of
/// them: how long it was, whether the app was watching, and whether the person was working.
public nonisolated struct ObservedInterval: Equatable, Sendable {
    public let start: Int
    public let end: Int
    /// The change in the reading across it, in basis points. Negative across a reset.
    public let deltaBasisPoints: Int
    /// False when the gap is longer than three times the cadence in force. Time nobody
    /// watched is not proven idle, and counting it as idle halves every activity estimate.
    public let isObserved: Bool

    public var seconds: Double { Double(end - start) }
    /// Work, not polling: the reading moved by more than the activity threshold.
    public var isActive: Bool {
        isObserved
            && Double(deltaBasisPoints) / 100 > BrainPolicy.activityThresholdPercent
    }

    /// Every interval of one window's ring, with the cadence in force read from the
    /// neighbours.
    ///
    /// `AdaptiveCadence` moves between 180 s and 1 800 s and it moves tiers slowly, so the
    /// gaps on either side of an interval are what the poller was doing at the time. The
    /// hard floor is the poller's own: nothing it schedules is ever closer together than
    /// that, so nothing shorter can be the cadence.
    public static func all(in window: UsageWindowTrace) -> [ObservedInterval] {
        let times = window.sampleTimes
        let used = window.sampleUsedBasisPoints
        guard times.count > 1 else { return [] }

        let floorSeconds = BrainPolicy.pollFloorSeconds
        var intervals: [ObservedInterval] = []
        intervals.reserveCapacity(times.count - 1)

        for index in 1..<times.count {
            let gap = Double(times[index] - times[index - 1])
            var cadence = Double.infinity
            if index >= 2 { cadence = min(cadence, Double(times[index - 1] - times[index - 2])) }
            if index + 1 < times.count { cadence = min(cadence, Double(times[index + 1] - times[index])) }
            let inForce = max(floorSeconds, cadence.isFinite ? cadence : floorSeconds)
            intervals.append(
                ObservedInterval(
                    start: times[index - 1],
                    end: times[index],
                    deltaBasisPoints: used[index] - used[index - 1],
                    isObserved: gap <= BrainPolicy.unobservedGapMultiple * inForce
                )
            )
        }
        return intervals
    }
}

/// When this person actually works, learned from the trace the app already keeps.
///
/// **This is the piece nobody in the category has, and it is the largest accuracy gain
/// available.** On the live trace only 8 of 80 session intervals moved at all. The
/// wall-clock rate is 3.5 percentage points an hour; the rate *while working* is twenty. So
/// a projection that multiplies a rate by the hours to the reset is charging the user for
/// the night, and a projection that multiplies the working rate by those same hours assumes
/// they never stop. The right projection is *rate while working × expected working hours
/// left*, and the second factor is what this type answers.
///
/// Each bucket is shrunk toward the person's own overall duty cycle by how much of that
/// bucket has been watched — Bühlmann credibility, one constant, one parameter. It degrades
/// exactly: with no data every bucket equals the overall rate, and with no overall rate the
/// profile answers nothing and the blend leans entirely on the ledger.
public nonisolated struct ActivityProfile: Equatable, Sendable {
    /// The clock the person keeps. Hour of week is a fact about their day, not about UTC.
    public let timeZone: TimeZone
    /// `p̂[b]`, already shrunk. Empty when nothing has been watched at all.
    let bucketDutyCycle: [Double]
    /// `p̄` — the person's overall duty cycle over the time the app watched.
    public let overallDutyCycle: Double
    /// Wall time the app actually watched, in hours.
    public let observedHours: Double
    /// Of that, the part that moved.
    public let activeHours: Double
    /// The earliest instant any of it covers, so a caller can ask what span these numbers
    /// are a measurement of.
    public let observedFrom: Date?

    public var hasEvidence: Bool { observedHours > 0 && !bucketDutyCycle.isEmpty }

    public init(
        timeZone: TimeZone,
        bucketDutyCycle: [Double],
        overallDutyCycle: Double,
        observedHours: Double,
        activeHours: Double,
        observedFrom: Date?
    ) {
        self.timeZone = timeZone
        self.bucketDutyCycle = bucketDutyCycle
        self.overallDutyCycle = overallDutyCycle
        self.observedHours = observedHours
        self.activeHours = activeHours
        self.observedFrom = observedFrom
    }

    /// A profile that knows nothing. Every query answers zero, which is what makes the blend
    /// fall back to the ledger without a branch anywhere else.
    public static func empty(timeZone: TimeZone) -> ActivityProfile {
        ActivityProfile(
            timeZone: timeZone,
            bucketDutyCycle: [],
            overallDutyCycle: 0,
            observedHours: 0,
            activeHours: 0,
            observedFrom: nil
        )
    }

    // MARK: - Building it

    /// The person's profile across the fleet.
    ///
    /// A person is working when *any* account moves, and the app is watching a stretch of
    /// wall time when *any* account observed it, so the answer is a union and not an average.
    /// Averaging would divide one person's working hours by the number of accounts they hold.
    public static func fleet(
        intervals: [[ObservedInterval]],
        timeZone: TimeZone
    ) -> ActivityProfile {
        make(
            spans: intervals.flatMap { $0.map { ($0.start, $0.end, $0.isActive, $0.isObserved) } },
            timeZone: timeZone
        )
    }

    private static func make(
        spans: [(start: Int, end: Int, active: Bool, observed: Bool)],
        timeZone: TimeZone
    ) -> ActivityProfile {
        // A sweep over the union, because two accounts watching the same hour watched one
        // hour. Depth counters rather than interval merging: two passes over 2n events
        // instead of a quadratic overlap test.
        var events: [(at: Int, covered: Int, active: Int)] = []
        events.reserveCapacity(spans.count * 2)
        for span in spans where span.observed && span.end > span.start {
            events.append((span.start, 1, span.active ? 1 : 0))
            events.append((span.end, -1, span.active ? -1 : 0))
        }
        guard !events.isEmpty else { return .empty(timeZone: timeZone) }
        events.sort { $0.at < $1.at }

        var covered = [Double](repeating: 0, count: BrainPolicy.activityBucketCount)
        var active = [Double](repeating: 0, count: BrainPolicy.activityBucketCount)
        var coveredDepth = 0
        var activeDepth = 0
        var index = 0
        var previous = events[0].at

        while index < events.count {
            let at = events[index].at
            if at > previous, coveredDepth > 0 {
                let seconds = Double(at - previous)
                let slot = bucket(forEpochSeconds: previous + (at - previous) / 2, timeZone: timeZone)
                covered[slot] += seconds
                if activeDepth > 0 { active[slot] += seconds }
            }
            while index < events.count, events[index].at == at {
                coveredDepth += events[index].covered
                activeDepth += events[index].active
                index += 1
            }
            previous = at
        }

        let totalCovered = covered.reduce(0, +)
        let totalActive = active.reduce(0, +)
        guard totalCovered > 0 else { return .empty(timeZone: timeZone) }
        let overall = totalActive / totalCovered

        // Bühlmann: believe the bucket in proportion to how much of it has been watched.
        var shrunk = [Double](repeating: overall, count: BrainPolicy.activityBucketCount)
        for slot in shrunk.indices where covered[slot] > 0 {
            let hours = covered[slot] / 3_600
            let credibility = hours / (hours + BrainPolicy.activityBucketCredibilityHours)
            shrunk[slot] = credibility * (active[slot] / covered[slot]) + (1 - credibility) * overall
        }

        return ActivityProfile(
            timeZone: timeZone,
            bucketDutyCycle: shrunk,
            overallDutyCycle: overall,
            observedHours: totalCovered / 3_600,
            activeHours: totalActive / 3_600,
            observedFrom: events.first.map { usageHistoryDate($0.at) }
        )
    }

    // MARK: - Asking it

    /// One hour of the forecast horizon: how long it is, and how much of it this person
    /// usually spends working.
    public nonisolated struct Slice: Equatable, Sendable {
        public let start: Date
        public let hours: Double
        public let expectedActiveHours: Double
    }

    /// The horizon cut into hour slices on the hour, so each slice belongs to one bucket.
    public func slices(from start: Date, to end: Date) -> [Slice] {
        guard end > start, hasEvidence else { return [] }
        var slices: [Slice] = []
        var at = start.timeIntervalSince1970
        let stop = end.timeIntervalSince1970
        while at < stop, slices.count < BrainPolicy.forecastSliceCap {
            let next = min(stop, ((at / 3_600).rounded(.down) + 1) * 3_600)
            let hours = (next - at) / 3_600
            let slot = Self.bucket(forEpochSeconds: Int(at.rounded(.down)), timeZone: timeZone)
            slices.append(
                Slice(
                    start: Date(timeIntervalSince1970: at),
                    hours: hours,
                    expectedActiveHours: bucketDutyCycle[slot] * hours
                )
            )
            at = next
        }
        return slices
    }

    /// `Â(t, T)` — expected working hours between two instants.
    ///
    /// Correct and slow: it walks the hours. A forecast asks this question many times
    /// inside one forward walk, and for that there is `horizon(from:)`, which answers the
    /// same question in two array lookups.
    public func expectedActiveHours(from start: Date, to end: Date) -> Double {
        slices(from: start, to: end).reduce(0) { $0 + $1.expectedActiveHours }
    }

    /// The same answer, precomputed once, for a caller that will ask it thousands of times.
    ///
    /// The forward simulation walks the week in quarter-hours and ranks every account at
    /// every step, and each ranking asks how many working hours lie between this instant and
    /// a reset. Answered by walking the hours, that is a few million hour-slices and a
    /// time-zone lookup for each of them — half a second on this Mac, on the utility queue,
    /// on every poll. Answered from a running total over the horizon it is two lookups and a
    /// subtraction, and it is the same arithmetic to the last decimal.
    public func horizon(from now: Date, hours: Int = BrainPolicy.horizonHours) -> WorkHorizon {
        guard hasEvidence else {
            return WorkHorizon(startEpoch: now.timeIntervalSince1970, cumulativeHours: [], dutyCycle: 0)
        }
        let start = (now.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600
        var cumulative = [Double](repeating: 0, count: hours + 1)
        var total = 0.0
        for index in 0..<hours {
            let at = start + Double(index) * 3_600
            total += bucketDutyCycle[Self.bucket(forEpochSeconds: Int(at), timeZone: timeZone)]
            cumulative[index + 1] = total
        }
        return WorkHorizon(startEpoch: start, cumulativeHours: cumulative, dutyCycle: overallDutyCycle)
    }

    /// Hour of day, and weekday or weekend, in the person's own time zone.
    ///
    /// Arithmetic rather than `Calendar`, because this runs once per interval of every ring
    /// on every poll and the only calendar fact it needs is which side of Saturday a day
    /// falls on. The zone's own offset is asked for at each instant, so the hour is right
    /// across a daylight-saving change.
    static func bucket(forEpochSeconds instant: Int, timeZone: TimeZone) -> Int {
        let offset = timeZone.secondsFromGMT(for: usageHistoryDate(instant))
        let local = instant + offset
        let day = Int((Double(local) / 86_400).rounded(.down))
        let hour = (local - day * 86_400) / 3_600
        // 1 January 1970 was a Thursday, which is index 3 counting Monday from zero.
        let weekday = (((day + 3) % 7) + 7) % 7
        return min(23, max(0, hour)) + (weekday >= 5 ? 24 : 0)
    }
}

/// `Â(t, T)` over a fixed horizon, precomputed.
///
/// A running total of expected working hours at each hour boundary from a start instant.
/// Reading it between two instants is a linear interpolation at each end and one subtraction.
/// Past the end of the horizon it extrapolates at the person's overall duty cycle, which is
/// what every bucket shrinks toward anyway, rather than answering zero.
public nonisolated struct WorkHorizon: Equatable, Sendable {
    let startEpoch: Double
    let cumulativeHours: [Double]
    let dutyCycle: Double

    public func expectedActiveHours(from start: Date, to end: Date) -> Double {
        guard end > start, !cumulativeHours.isEmpty else { return 0 }
        return max(0, value(at: end.timeIntervalSince1970) - value(at: start.timeIntervalSince1970))
    }

    /// The same hours, discounted — what the app is willing to extrapolate to.
    public func discountedActiveHours(from start: Date, to end: Date, damping: Double) -> Double {
        discountedActiveHours(expectedActiveHours(from: start, to: end), damping: damping)
    }

    /// The discounted hours between two instants of the horizon, both measured from `origin`.
    ///
    /// The discount is anchored at one instant and not at each end, because it is a statement
    /// about how far ahead the app is extrapolating: an hour of work the day after tomorrow
    /// counts for less than an hour of work this afternoon, whichever slice asks about it.
    /// Consecutive calls therefore telescope, so a walk that debits slice by slice arrives at
    /// exactly the number the forecast named for the whole span.
    public func discountedIncrement(
        origin: Date,
        from start: Date,
        to end: Date,
        damping: Double
    ) -> Double {
        discountedActiveHours(expectedActiveHours(from: origin, to: end), damping: damping)
            - discountedActiveHours(expectedActiveHours(from: origin, to: start), damping: damping)
    }
}

/// Gardner & McKenzie's damped horizon, in closed form and in the unit the rate is measured in.
///
/// `∫₀^A φ^a da = (1 − φ^A) / −ln φ`. Written once, because every number a person reads about a
/// window has to be discounted by the same curve as the landing: the forecast and the count
/// of sessions there is time for. Separate derivations discounting differently would tell two
/// stories about one week.
///
/// **The unit is an hour of this person's own work, not an hour of the clock.** The rate is
/// percentage points per working hour, so damping on working hours is the same unit twice, and
/// the answer does not change when a walk is cut into quarter-hours instead of hours.
public nonisolated func discountedActiveHours(_ activeHours: Double, damping: Double) -> Double {
    guard activeHours > 0 else { return 0 }
    guard damping > 0, damping < 1 else { return activeHours }
    return (1 - pow(damping, activeHours)) / -log(damping)
}

nonisolated extension WorkHorizon {
    fileprivate func discountedActiveHours(_ activeHours: Double, damping: Double) -> Double {
        QotaFolioModel.discountedActiveHours(activeHours, damping: damping)
    }

    private func value(at instant: Double) -> Double {
        let offset = (instant - startEpoch) / 3_600
        guard offset > 0 else { return offset * dutyCycle }
        let last = Double(cumulativeHours.count - 1)
        guard offset < last else {
            return cumulativeHours[cumulativeHours.count - 1] + (offset - last) * dutyCycle
        }
        let index = Int(offset)
        let fraction = offset - Double(index)
        return cumulativeHours[index]
            + fraction * (cumulativeHours[index + 1] - cumulativeHours[index])
    }
}
