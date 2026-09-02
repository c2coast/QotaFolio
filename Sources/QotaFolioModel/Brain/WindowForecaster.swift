import Foundation

/// Where one window lands, and how sure the app is.
///
/// The method is a **credibility blend**, not a better slope. A line projected from the samples
/// in the window in hand is weakest exactly where it is asked most: early, when there are barely
/// any. This blends two estimates — what the last few windows actually cost, and what this
/// window is doing so far — weighted by how much
/// *active* evidence this window has produced. Cold-start damping then stops being a patch
/// for the first tenth of a window and becomes the formula itself: two windows at the same
/// elapsed fraction get different weights when one of them contains evidence and the other
/// does not, which is the correct behaviour and is what an elapsed-fraction gate cannot
/// express.
public nonisolated enum WindowForecaster {
    /// Everything one window's forecast reads that is not the window itself.
    public nonisolated struct Context: Sendable {
        /// The person's activity profile, across the whole fleet: one consumer, one rhythm.
        public let profile: ActivityProfile
        /// Expected working hours over the horizon, precomputed once for the whole fleet.
        /// **The one horizon.** Every reader shares the same object, so nothing the user
        /// sees is discounted twice or not at all.
        public let horizon: WorkHorizon
        /// Every close this window has had at every account of the fleet, newest first, and
        /// Bühlmann's `K` measured across those accounts.
        ///
        /// The closes rather than a finished prior, because the prior has to be made at
        /// whichever coverage the band is being drawn at, and because an account with no
        /// history of its own must be able to borrow all of it.
        public let fleetClosesNewestFirst: [Double]
        public let fleetCredibilityConstant: Double?
        public let now: Date

        public init(
            profile: ActivityProfile,
            horizon: WorkHorizon,
            fleetClosesNewestFirst: [Double] = [],
            fleetCredibilityConstant: Double? = nil,
            now: Date
        ) {
            self.profile = profile
            self.horizon = horizon
            self.fleetClosesNewestFirst = fleetClosesNewestFirst
            self.fleetCredibilityConstant = fleetCredibilityConstant
            self.now = now
        }
    }

    public static func forecast(
        window: UsageWindowTrace,
        ledger: WindowLedger,
        context: Context
    ) -> WindowForecast {
        let now = context.now
        let openedAt = usageHistoryDate(window.currentOpenedAt)
        let observedAt = usageHistoryDate(window.lastObservedAt)
        let resetsAt = window.currentResetsAt.map(usageHistoryDate)
        let usedPercent = usagePercent(
            fromBasisPoints: window.lastUsedBasisPoints ?? window.sampleUsedBasisPoints.last ?? 0
        )

        // MARK: What this occurrence has shown

        let intervals = ObservedInterval.all(in: window)
            .filter { $0.end > window.currentOpenedAt }
        let activeIntervals = intervals.filter(\.isActive)
        let activeSeconds = activeIntervals.reduce(0) { $0 + $1.seconds }
        let activeHours = activeSeconds / 3_600
        let longestRecentGap = intervals.suffix(BrainPolicy.bandGapLookback)
            .reduce(0.0) { max($0, $1.seconds) }

        let elapsedFraction: Double = {
            guard let resetsAt else { return 0 }
            let length = resetsAt.timeIntervalSince(openedAt)
            guard length > 0 else { return 1 }
            return min(1, max(0, now.timeIntervalSince(openedAt) / length))
        }()

        let rate = ratePerActiveHour(window: window, intervals: intervals)
        let expectedActiveHoursRemaining = resetsAt.map {
            context.horizon.expectedActiveHours(from: now, to: $0)
        } ?? 0

        // MARK: The blend

        // Credibility by information, not by clock. Past ninety percent elapsed the reading
        // is the truth and the prior has nothing left to say.
        let credibility = elapsedFraction > BrainPolicy.blendCertaintyElapsedFraction
            ? 1
            : activeHours / (activeHours + BrainPolicy.blendCredibilityActiveHours)
        let damping = BrainPolicy.dampingFloor + BrainPolicy.dampingRange * credibility
        let dampedActiveHours = discountedActiveHours(expectedActiveHoursRemaining, damping: damping)
        let observedLanding = min(100, usedPercent + (rate ?? 0) * dampedActiveHours)

        // What may be *claimed* rests on how many times this window has been watched from one
        // end to the other. Active intervals are observations of the rate, not of the
        // landing, so they buy a narrower band and never a coverage number.
        let claimed = claimableCoverage(samples: ledger.usableCount)
        let widest = claimed
            ?? BrainPolicy.bandCoverageLadder[BrainPolicy.bandCoverageLadder.count - 1].coverage

        /// What the last few windows cost, at one coverage — this account's own history where
        /// it has some, the fleet's where it has none.
        ///
        /// **The fleet is the credibility population.** An account estimated from its own history
        /// alone leaves how much to trust it a guess. Five accounts belonging to one person doing
        /// the same work make Bühlmann's two variances estimable, so `K` is measured rather than
        /// guessed — and an account connected an hour ago answers from the fleet's history
        /// instead of from nothing.
        func priorEdges(at coverage: Double) -> LedgerPrior? {
            let fleet = LedgerPrior.make(
                recentClosesNewestFirst: context.fleetClosesNewestFirst,
                coverage: coverage
            )
            guard let own = LedgerPrior.make(
                recentClosesNewestFirst: ledger.recentCloses,
                coverage: coverage
            ) else { return fleet }
            return own.credibilityBlended(towards: fleet, k: context.fleetCredibilityConstant)
        }
        let prior = priorEdges(at: widest)

        let landing = min(
            100,
            max(
                usedPercent,
                credibility * observedLanding + (1 - credibility) * (prior?.landing ?? observedLanding)
            )
        )

        // MARK: The band

        let paths = bootstrapPaths(
            from: activeIntervals,
            usedPercent: usedPercent,
            activeHoursRemaining: dampedActiveHours,
            seed: seed(windowKey: window.key, openedAt: window.currentOpenedAt)
        )
        func band(at coverage: Double) -> ForecastBand {
            let tail = (1 - coverage) / 2
            let observedLow = quantile(of: paths, p: tail) ?? observedLanding
            let observedHigh = quantile(of: paths, p: 1 - tail) ?? observedLanding
            // Below the distribution-free floor the prior has no edges at all, and the honest
            // interval on that side is the whole line.
            let edges = priorEdges(at: coverage)
            let low = credibility * observedLow + (1 - credibility) * (edges?.low ?? usedPercent)
            let high = credibility * observedHigh + (1 - credibility) * (edges?.high ?? 100)
            return floored(
                low: low,
                high: high,
                usedPercent: usedPercent,
                landing: landing,
                rate: rate,
                longestRecentGap: longestRecentGap
            )
        }

        // Drawn graded — nested levels at decreasing opacity — because the Bank of England
        // published in 1998 what one shaded area does to a reader: it is read as upper and
        // lower bounds rather than as a spread of probabilities, and it encourages the eye to
        // settle on an apparently precise central line. Both failures are available to this
        // app verbatim.
        //
        // Where no coverage may be claimed the pair is still drawn and simply says nothing
        // about itself. Wilks: the sample range of n points covers (n−1)/(n+1) of the
        // distribution in expectation, so at three completed windows this is a real interval
        // with no coverage to its name.
        let inner = band(at: BrainPolicy.bandInnerCoverage)
        let outerPair = band(at: widest)
        let bands: [ForecastBand] = [
            ForecastBand(
                coverage: claimed == nil ? nil : BrainPolicy.bandInnerCoverage,
                lowPercent: inner.lowPercent,
                highPercent: inner.highPercent
            ),
            ForecastBand(coverage: claimed, lowPercent: outerPair.lowPercent, highPercent: outerPair.highPercent),
        ]

        let evidence = ForecastEvidence(
            activeHours: activeHours,
            completedWindows: ledger.usableCount,
            credibility: credibility,
            ratePerActiveHour: rate,
            expectedActiveHoursRemaining: expectedActiveHoursRemaining,
            discountedActiveHoursRemaining: dampedActiveHours,
            damping: damping,
            elapsedFraction: elapsedFraction,
            longestRecentPollGap: longestRecentGap,
            observedAt: observedAt
        )

        // MARK: The verdict, and the five silences

        let outer = bands.last
        let silence = silence(
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            observedAt: observedAt,
            now: now,
            activeSeconds: activeSeconds,
            completedWindows: ledger.usableCount,
            band: outer
        )
        let verdict: WindowVerdict
        var namedLanding: Double? = landing
        if usedPercent >= 100 {
            verdict = .spent
        } else if let silence {
            // No projection, no verdict tone, no band — except the last of the five, where
            // the band is exactly what is left to say.
            verdict = .silent(silence)
            namedLanding = nil
        } else if landing >= 100 {
            verdict = .runningOut(
                at: limitCrossing(
                    usedPercent: usedPercent,
                    rate: rate,
                    damping: damping,
                    slices: resetsAt.map { context.profile.slices(from: now, to: $0) } ?? []
                )
            )
        } else if (outer?.highPercent ?? 100) > 100 - BrainPolicy.verdictSpareHeadroomPercent {
            verdict = .cuttingItClose
        } else {
            verdict = .onCourse
        }

        return WindowForecast(
            windowKey: window.key,
            scope: window.scope,
            period: window.period.period,
            usedPercent: usedPercent,
            resetsAt: resetsAt,
            occurrenceOpenedAt: openedAt,
            landingPercent: namedLanding,
            bands: drawnBands(bands, whenSilent: silence),
            coverageClaimed: silence == nil ? claimed : nil,
            verdict: verdict,
            evidence: evidence
        )
    }

    /// What is drawn once a silence has been declared.
    ///
    /// Four of the five silences leave nothing to draw. The fifth — a band wider than sixty
    /// points — is the one where the band is the whole of the answer: the instrument draws
    /// the range greyed and refuses to name a number inside it.
    private static func drawnBands(
        _ bands: [ForecastBand],
        whenSilent silence: WindowSilence?
    ) -> [ForecastBand] {
        guard let silence else { return bands }
        guard case .tooEarlyToSay = silence, let outer = bands.last else { return [] }
        return [ForecastBand(coverage: nil, lowPercent: outer.lowPercent, highPercent: outer.highPercent)]
    }

    // MARK: - The pieces

    /// Percentage points per **working** hour, over the occurrence in hand.
    ///
    /// The series is cleaned onto the monotone cone first, because consumption inside one
    /// occurrence cannot fall and the live trace contains a −5.00 pp step. The slope is then
    /// taken against cumulative *active* hours rather than wall time: every idle stretch is a
    /// tie in x and Sen's rule drops tied pairs, so the answer is the rate while working and
    /// not a rate averaged over the night.
    static func ratePerActiveHour(
        window: UsageWindowTrace,
        intervals: [ObservedInterval]
    ) -> Double? {
        let samples = zip(window.sampleTimes, window.sampleUsedBasisPoints)
            .filter { $0.0 >= window.currentOpenedAt }
        guard samples.count > 1 else { return nil }

        let cleaned = RobustRate.monotoneIncreasingFit(
            samples.map { usagePercent(fromBasisPoints: $0.1) }
        )
        let times = samples.map(\.0)
        let activeSecondsByEnd = Dictionary(
            intervals.filter(\.isActive).map { ($0.end, $0.seconds) },
            uniquingKeysWith: { first, _ in first }
        )

        // One point per distinct position on the active-hours axis. Points that share a
        // position are the same measurement repeated, and Sen's rule drops every pair between
        // them; keeping the last of each run is the whole of the information they carry, at a
        // fraction of the pairs.
        var x: [Double] = []
        var y: [Double] = []
        var cumulative = 0.0
        for (index, time) in times.enumerated() {
            cumulative += (activeSecondsByEnd[time] ?? 0) / 3_600
            if let last = x.last, last == cumulative {
                y[y.count - 1] = cleaned[index]
            } else {
                x.append(cumulative)
                y.append(cleaned[index])
            }
        }
        if x.count > BrainPolicy.rateSampleCap {
            x = Array(x.suffix(BrainPolicy.rateSampleCap))
            y = Array(y.suffix(BrainPolicy.rateSampleCap))
        }
        return RobustRate.senSlope(x: x, y: y).map { max(0, $0) }
    }

    /// What may be claimed from `n` observations.
    ///
    /// A distribution-free interval at coverage 1−α needs `n ≥ 1/α − 1` — the split-conformal
    /// finite-sample identity. Below the floor the honest interval is the whole line, and
    /// `nil` here is how that is said.
    static func claimableCoverage(samples: Int) -> Double? {
        for step in BrainPolicy.bandCoverageLadder where samples >= step.minimumSamples {
            // n ≥ 19 makes 95% available; 90% is what is drawn, and is the honest headline.
            return step.coverage == 0.95 ? 0.90 : step.coverage
        }
        return nil
    }

    /// Sample paths for the observation side, resampled from this occurrence's own burn.
    ///
    /// Bootstrapping the residuals rather than assuming a normal `±c·σ` interval, for two
    /// reasons that are facts about the quantity: consumption is bounded at 100% and piles up
    /// near the limit, so a symmetric interval is wrong on both counts and would spill past
    /// the limit. A resampled path cannot, because it is clamped.
    static func bootstrapPaths(
        from activeIntervals: [ObservedInterval],
        usedPercent: Double,
        activeHoursRemaining: Double,
        seed: UInt64
    ) -> [Double] {
        let rates = activeIntervals.compactMap { interval -> Double? in
            guard interval.seconds > 0 else { return nil }
            return Double(interval.deltaBasisPoints) / 100 / (interval.seconds / 3_600)
        }
        guard !rates.isEmpty, activeHoursRemaining > 0 else { return [] }

        let blocks = max(
            1,
            Int((activeHoursRemaining / BrainPolicy.bandBootstrapBlockActiveHours).rounded(.up))
        )
        let blockHours = activeHoursRemaining / Double(blocks)
        var generator = SeededGenerator(seed: seed)
        var totals: [Double] = []
        totals.reserveCapacity(BrainPolicy.bandBootstrapPaths)
        for _ in 0..<BrainPolicy.bandBootstrapPaths {
            var used = usedPercent
            for _ in 0..<blocks {
                used += rates[Int(generator.next() % UInt64(rates.count))] * blockHours
                if used >= 100 { used = 100; break }
            }
            totals.append(used)
        }
        totals.sort()
        return totals
    }

    private static func quantile(of sortedPaths: [Double], p: Double) -> Double? {
        EmpiricalQuantile.value(sorted: sortedPaths, p: p)
    }

    /// The band's honest floor, and the two facts about the input it is made of.
    ///
    /// One unobserved poll interval of burn — the app polls as slowly as every thirty
    /// minutes, so a claim finer than that is a claim about time it did not watch — and one
    /// percentage point of provider quantisation, because every value on the wire is a whole
    /// percent. Nobody else floors a band on the sampling gap, and it is the difference
    /// between a band that is honest and a band that is decorative.
    static func floored(
        low: Double,
        high: Double,
        usedPercent: Double,
        landing: Double,
        rate: Double?,
        longestRecentGap: TimeInterval
    ) -> ForecastBand {
        let watchedGap = min(longestRecentGap, BrainPolicy.pollCeilingSeconds)
        let minimumWidth = (rate ?? 0) * watchedGap / 3_600 + BrainPolicy.bandQuantisationFloorPercent

        var lowEdge = min(low, landing)
        var highEdge = max(high, landing)
        let shortfall = minimumWidth - (highEdge - lowEdge)
        if shortfall > 0 {
            lowEdge -= shortfall / 2
            highEdge += shortfall / 2
        }
        // Consumption cannot fall, and cannot pass the limit. Whichever edge a clamp takes
        // width from, the other one gives it back, so the floor survives both clamps.
        lowEdge = max(usedPercent, lowEdge)
        highEdge = min(100, max(highEdge, lowEdge + min(minimumWidth, 100 - lowEdge)))
        lowEdge = max(usedPercent, min(lowEdge, max(usedPercent, highEdge - minimumWidth)))
        return ForecastBand(coverage: nil, lowPercent: lowEdge, highPercent: highEdge)
    }

    /// When the projected path reaches the limit, walking the same slices the projection did.
    ///
    /// The instant is what the sentence names — "Limit at 15:40" — so it has to come from the
    /// same arithmetic as the landing, or the row and its own reason disagree.
    static func limitCrossing(
        usedPercent: Double,
        rate: Double?,
        damping: Double,
        slices: [ActivityProfile.Slice]
    ) -> Date? {
        guard let rate, rate > 0 else { return nil }
        var used = usedPercent
        var elapsed = 0.0
        for slice in slices where slice.expectedActiveHours > 0 {
            let next = elapsed + slice.expectedActiveHours
            let gain = rate * (
                discountedActiveHours(next, damping: damping)
                    - discountedActiveHours(elapsed, damping: damping)
            )
            elapsed = next
            guard gain > 0 else { continue }
            if used + gain >= 100 {
                let fraction = (100 - used) / gain
                return slice.start.addingTimeInterval(slice.hours * 3_600 * fraction)
            }
            used += gain
        }
        return nil
    }

    /// The five silences, tested in order. The first one that holds is the one the row says.
    static func silence(
        usedPercent: Double,
        resetsAt: Date?,
        observedAt: Date,
        now: Date,
        activeSeconds: TimeInterval,
        completedWindows: Int,
        band: ForecastBand?
    ) -> WindowSilence? {
        guard resetsAt != nil else { return .noResetInstant }
        if now.timeIntervalSince(observedAt) > BrainPolicy.silenceStaleReadingAge {
            return .readingIsStale(observedAt: observedAt)
        }
        if usedPercent <= 0 { return .notStarted }
        if completedWindows < BrainPolicy.silenceMinimumCompletedWindows,
           activeSeconds < BrainPolicy.silenceMinimumActiveEvidence {
            return .learningYourPattern
        }
        if let band, band.widthPercent > BrainPolicy.silenceUninformativeBandPercent {
            return .tooEarlyToSay
        }
        return nil
    }

    /// A seed that is stable while the occurrence is, so the band does not shimmer between
    /// two polls that learned nothing, and is redrawn when a new occurrence opens.
    static func seed(windowKey: String, openedAt: Int) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in windowKey.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x1000_0000_01B3
        }
        return hash ^ UInt64(bitPattern: Int64(openedAt))
    }
}
