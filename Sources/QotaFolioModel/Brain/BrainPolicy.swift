import Foundation

/// Every number the brain uses, in one place, with the reason it is that number.
///
/// Every number below is either taken from the method the brain implements, carried here with
/// the reason it is that number, or chosen by this app — and where it is chosen, the reason
/// says what it was measured against: the provider's quantisation, the poller's own tiers, or
/// the shape of a real trace. Never against a feeling about safety.
///
/// Nothing here is a setting. A constant that would have to be a setting is a sign that the
/// app is asking the user for data it already holds. Sessions left in the week is the worked
/// example, and the answer there was to measure rather than to ask.
public nonisolated enum BrainPolicy {
    /// The closest together and the furthest apart the poller will ever place two requests.
    /// `UsageHistoryPolicy` holds them, because the storage layer needs them too and both
    /// live in this target while the poller does not. `BrainKnowsThePollerTests` pins them to
    /// `PollingPolicy`'s own, so the copy cannot go stale in silence.
    public static let pollFloorSeconds = UsageHistoryPolicy.pollFloorSeconds
    public static let pollCeilingSeconds = UsageHistoryPolicy.pollCeilingSeconds

    // MARK: - Activity

    /// How much a reading must move for the interval to count as work, in percentage points.
    ///
    /// Comfortably above nothing, and comfortably below the whole percentage point both
    /// providers quantise to, so a single reported step counts as one active interval.
    public static let activityThresholdPercent = 0.10

    /// Hour of day × {weekday, weekend}. One hundred and sixty-eight buckets is the shape
    /// the profile wants and forty-eight is the shape eight days of trace can fill; the
    /// collapse costs the difference between Tuesday and Thursday, which nobody has the data
    /// to tell apart yet.
    public static let activityBucketCount = 48

    /// Bühlmann's credibility constant for one bucket, in observed hours.
    ///
    /// `Z = 1/2` exactly when `n = K`, so the number reads in plain words: how many observed
    /// hours in this bucket before the bucket is believed over the person's own average.
    /// Four hours is roughly two weeks of one hour-of-week slot.
    public static let activityBucketCredibilityHours = 4.0

    /// A gap longer than this multiple of the cadence in force was not watched, and time
    /// nobody watched is not proven idle.
    ///
    /// The live trace holds a 57 542-second gap on the weekly ring. Counting it as sixteen
    /// hours of proven idleness would halve every activity estimate on this Mac. The cadence
    /// in force is read from the gaps on either side, because `AdaptiveCadence` changes tier
    /// slowly and the neighbours are what it was doing at the time.
    public static let unobservedGapMultiple = 3.0

    // MARK: - The in-window observation

    /// The rate is measured over the most recent this-many distinct active positions.
    ///
    /// Theil–Sen is a median over every pair, so the cost is quadratic in the number of
    /// positions: forty-eight of them is 1,128 slopes, and the whole assessment's budget is a
    /// few thousand operations per window. A median over a thousand slopes is not improved by
    /// ten thousand more — the estimator's breakdown point is 29.3% at every sample size —
    /// and the positions dropped are the oldest, which is the right end to drop: they are the
    /// least evidence about the rate now.
    ///
    /// Positions are created by work, not by polling. The live trace has twenty-two of them
    /// in twenty-six hours, so this bound is not reached in ordinary use at all.
    public static let rateSampleCap = 48

    /// Gardner & McKenzie's damped trend, with fpp3's range and a slope that rises with
    /// evidence: 0.80 with none, 0.98 with plenty. An undamped trend over-forecasts at long
    /// horizons, which is the documented reason the damped method exists.
    public static let dampingFloor = 0.80
    public static let dampingRange = 0.18

    // MARK: - The ledger prior

    /// A completed occurrence that cost less than this did no work, and is not evidence
    /// about what a working window costs. One of the three occurrences on this Mac closed at
    /// 0.00% — five hours in which nothing happened.
    public static let ledgerActiveClosePercent = 2.0

    /// Recency weighting over occurrences-ago. A person's rhythm drifts. At λ = 1 this is a
    /// plain quantile, so it is a dial and not a dependency.
    public static let ledgerRecencyLambda = 0.85

    /// How many completed occurrences the prior reads. Eight days of five-hour windows is
    /// about thirty-eight, and the ledger holds sixty-four; reading them all would weight a
    /// fortnight-old rhythm at λ⁶⁴, which is nothing.
    public static let ledgerDepth = 24

    // MARK: - The blend

    /// Bühlmann–Straub with active hours as the exposure. `Z = A / (A + K_A)`.
    ///
    /// Three quarters of an active hour before this window's own evidence outweighs the
    /// ledger. This is the whole of the cold-start answer and it is the same formula as the
    /// warm-start answer: credibility damps by information, not by clock, so two windows at
    /// the same elapsed fraction get different weights when one of them contains evidence.
    public static let blendCredibilityActiveHours = 0.75

    /// Past this much of the window elapsed, the reading is the truth and the prior has
    /// nothing left to say.
    public static let blendCertaintyElapsedFraction = 0.90

    // MARK: - The band

    /// The distribution-free floor: an interval at coverage 1−α needs `n ≥ 1/α − 1`. Below
    /// four completed windows no coverage may be claimed at all; the range may still be
    /// drawn, and `coverageClaimed` says nothing.
    public static let bandCoverageLadder: [(minimumSamples: Int, coverage: Double)] = [
        (19, 0.95),
        (9, 0.90),
        (4, 0.80),
    ]

    /// Drawn inside every claimed band, so the picture is graded rather than a single shaded
    /// area read as upper and lower bounds — the Bank of England's 1996 finding, verbatim.
    public static let bandInnerCoverage = 0.50

    /// Paths drawn for the observation side of the band.
    ///
    /// Two hundred paths of at most a few dozen blocks is a few thousand floating-point
    /// operations per window, which is what the brain's whole budget is. The seed is derived
    /// from the occurrence, so the band does not shimmer between two polls that learned
    /// nothing.
    public static let bandBootstrapPaths = 200

    /// One block of resampled burn, in active hours.
    public static let bandBootstrapBlockActiveHours = 1.0

    /// The provider's quantisation, in percentage points. Every value in the live file is a
    /// whole percent, so a band narrower than this is a lie about the input.
    public static let bandQuantisationFloorPercent = 1.0

    /// Intervals read back to here when the band's width floor asks for the longest recent
    /// poll gap. Eight polls is half an hour of working cadence, so an overnight leaves the
    /// band wide and half an hour of real polls narrows it again.
    public static let bandGapLookback = 8

    // MARK: - The verdict

    /// An account is called on course only when even the pessimistic path lands with this
    /// much to spare. The asymmetry is deliberate: a false "on course" costs the user a
    /// blocked afternoon, a false "cutting it close" costs a glance.
    public static let verdictSpareHeadroomPercent = 10.0

    // MARK: - Silence

    /// Under this much active evidence, with fewer than three completed occurrences, there is
    /// nothing to blend and nothing to project.
    public static let silenceMinimumActiveEvidence: TimeInterval = 15 * 60
    public static let silenceMinimumCompletedWindows = 3

    /// A projection older than this is about a past that has moved.
    public static let silenceStaleReadingAge: TimeInterval = 45 * 60

    /// An interval this wide is not a statement. The point estimate is suppressed and the
    /// band is drawn greyed: an honest instrument may draw a range and refuse to name a
    /// number inside it.
    public static let silenceUninformativeBandPercent = 60.0

    // MARK: - Sessions left in the week

    /// The aggregate needs this many completed working sessions before a per-session cost
    /// means anything.
    public static let sessionsLeftMinimumOccurrences = 3

    /// And this much aggregate weekly movement. One percentage point over a whole span is
    /// one quantisation step, and is not a measurement.
    public static let sessionsLeftMinimumWeeklyMovementPercent = 3.0

    /// How far back the aggregate reads. The trace keeps eight and a half days; a week and a
    /// day of it is the span over which "what a working session costs the week" is a fact
    /// about the rhythm the user is in now.
    public static let sessionsLeftSpan: TimeInterval = 8 * 86_400

    // MARK: - Availability

    /// Below this much session headroom, an account has nothing spendable in it — and on a
    /// provider that reports whole percentage points, three points is three quantisation
    /// steps of noise.
    public static let availableHeadroomPercent = 3.0

    /// The longest horizon any forward walk runs for, in hour slices. A window that names a
    /// reset a year out is a provider bug, not a horizon, and the loop is not allowed to
    /// become one.
    public static let forecastSliceCap = 9 * 24

    /// Hours of expected work precomputed once per assessment. The furthest thing anybody
    /// asks about is a weekly reset at the end of the walk's own horizon, which the walk can
    /// push one week further when it applies a reset.
    public static let horizonHours = 9 * 24 + 7 * 24

    // MARK: - Alerts

    /// A reset is worth announcing for this long after it happened; past that the fresh
    /// window is not news.
    public static let alertFreshWindowAge: TimeInterval = 30 * 60

    /// Below this much stranded quota there is nothing to tell anybody: it is inside the
    /// provider's own quantisation of a week.
    public static let alertStrandingPercent = 5.0

    // MARK: - Review

    /// The soonest the brain asks to be looked at again, and the longest it will wait when
    /// nothing is due. The floor keeps a boundary that is one second away from arming a wake
    /// per second; the ceiling keeps a fleet with no reset instants from going quiet for ever.
    public static let reviewFloor: TimeInterval = 60
    public static let reviewCeiling: TimeInterval = 60 * 60
}
