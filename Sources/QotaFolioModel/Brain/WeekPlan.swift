import Foundation

/// How many more working sessions this week can pay for, and whether the week or the clock
/// runs out first.
///
/// **Neither of the two obvious ways to compute it survives contact with a real trace.** Taking
/// the median of quantised per-occurrence differences answers zero whenever most occurrences
/// cost less than one percentage point — "an unlimited number of sessions remain", which is not
/// a rounding error but the wrong answer. And `floor(remaining / 5 hours)` is not a count of
/// sessions anybody will open: seven days divided by five hours is thirty-three. Asking the
/// person for a working-days count patches that by requesting data the app already holds.
///
/// **Everything here is the weekly window's own forecast, counted in sessions.** The cost of a
/// session is the one thing measured separately, because it is a cost and not a rate: one
/// subtraction over a long span, divided by an integer count. How many sessions there is time
/// for is the forecast's own discounted working hours divided by how long a session of this
/// person's costs — which is that same cost divided by that same rate. So the two counts and
/// the row above them cannot disagree: `funded < time for` is true exactly when the forecast
/// lands past the limit, and `funded > time for` exactly when it lands short of it.
public nonisolated struct WeekPlan: Equatable, Sendable {
    /// Weekly percentage points one working session costs. One subtraction over a long span,
    /// divided by an integer count, so the quantisation error is a point on the whole span
    /// rather than a point on every occurrence.
    public let weeklyCostPerSessionPercent: Double
    /// Completed working sessions the aggregate rests on.
    public let observedSessions: Int
    /// What the week can still pay for.
    public let fundedSessions: Int
    /// What there is time for before the week resets, from the person's own rhythm rather
    /// than from a setting — and from the same forecast the row above draws.
    public let sessionsThereIsTimeFor: Int?
    /// When the week runs out before its reset, taken from the weekly window's own forecast.
    ///
    /// From the forecast and not from a second walk, because a panel that names two different
    /// days for the same event has told the user nothing.
    public let runsOutAt: Date?

    public init(
        weeklyCostPerSessionPercent: Double,
        observedSessions: Int,
        fundedSessions: Int,
        sessionsThereIsTimeFor: Int?,
        runsOutAt: Date?
    ) {
        self.weeklyCostPerSessionPercent = weeklyCostPerSessionPercent
        self.observedSessions = observedSessions
        self.fundedSessions = fundedSessions
        self.sessionsThereIsTimeFor = sessionsThereIsTimeFor
        self.runsOutAt = runsOutAt
    }

    /// True when there is more week than there are working hours to spend it in. The quantity
    /// that will expire belongs to the fleet's plan, which walks the whole horizon; this is
    /// only the fact.
    public var willStrand: Bool {
        guard let sessionsThereIsTimeFor else { return false }
        return sessionsThereIsTimeFor < fundedSessions
    }

    /// The aggregate, or `nil` — which is the app saying nothing, and is often the correct answer.
    ///
    /// Silent under three completed working sessions, and silent under three points of
    /// aggregate weekly movement: a one-point movement over a whole span is one quantisation
    /// step and is not a measurement.
    public static func make(
        weekly: UsageWindowTrace?,
        weeklyForecast: WindowForecast?,
        sessionLedger: WindowLedger,
        now: Date
    ) -> WeekPlan? {
        guard let weekly, weekly.currentResetsAt != nil else { return nil }
        let spanStart = max(
            weekly.sampleTimes.first ?? 0,
            usageHistoryEpochSeconds(now.addingTimeInterval(-BrainPolicy.sessionsLeftSpan))
        )
        let weeklyMovement = rise(in: weekly, from: spanStart)
        let sessions = sessionLedger.usable.filter {
            usageHistoryEpochSeconds($0.closedAt) >= spanStart
        }.count

        guard sessions >= BrainPolicy.sessionsLeftMinimumOccurrences,
              weeklyMovement >= BrainPolicy.sessionsLeftMinimumWeeklyMovementPercent
        else { return nil }

        let cost = weeklyMovement / Double(sessions)
        guard cost > 0 else { return nil }
        let remaining = max(
            0,
            100 - usagePercent(fromBasisPoints: weekly.lastUsedBasisPoints ?? 0)
        )

        // How many the person has time for, off the landing itself. The row says where the
        // week ends up; the distance from here to there, over the cost of one session, is how
        // many sessions there is time for. Reading it from the landing rather than from the
        // rate and the hours separately is what makes the two counts agree with the row by
        // construction: there is time for fewer than the week funds exactly when the landing
        // is short of the limit, and for more exactly when it is past it.
        var timeFor: Int?
        if let landing = weeklyForecast?.landingPercent, let used = weeklyForecast?.usedPercent {
            timeFor = Int((max(0, landing - used) / cost).rounded(.down))
        }
        var runsOutAt: Date?
        if case .runningOut(let at) = weeklyForecast?.verdict { runsOutAt = at }

        return WeekPlan(
            weeklyCostPerSessionPercent: cost,
            observedSessions: sessions,
            fundedSessions: Int((remaining / cost).rounded(.down)),
            sessionsThereIsTimeFor: timeFor,
            runsOutAt: runsOutAt
        )
    }

    /// How far a ring rose over a span.
    ///
    /// The sum of its positive steps, not the difference of its ends, because the samples run
    /// **across** resets: a span that contains a reset would otherwise report the week as
    /// having gone backwards. Where no reset falls inside, the sum of the positive steps is
    /// the difference of the ends, exactly.
    static func rise(in window: UsageWindowTrace, from start: Int) -> Double {
        var total = 0
        var previous: Int?
        for (time, used) in zip(window.sampleTimes, window.sampleUsedBasisPoints) where time >= start {
            if let previous, used > previous { total += used - previous }
            previous = used
        }
        return usagePercent(fromBasisPoints: total)
    }
}
