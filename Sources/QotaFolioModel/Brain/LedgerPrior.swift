import Foundation

/// One ended occurrence, read back honestly.
///
/// The stored row is a statement made at one poll and the ring is a second witness that is
/// already on disk. Where they disagree the ring wins, because consumption inside a tumbling
/// occurrence only rises and the maximum is therefore the close.
public nonisolated struct LedgerObservation: Equatable, Sendable {
    public let openedAt: Date
    public let closedAt: Date
    /// The close, corrected against the ring.
    public let closePercent: Double
    /// What this occurrence cost the account's week, when that can be said at all.
    public let weeklyCostPercent: Double?
    /// True when the ring or the sequence shows this row is not a distinct occurrence.
    public let isRestatement: Bool

    /// Did work happen in it? A window nobody worked in is not evidence about what a working
    /// window costs.
    public var isWorking: Bool { closePercent >= BrainPolicy.ledgerActiveClosePercent }
    public var isUsable: Bool { !isRestatement && isWorking }
}

/// The ledger of one window, corrected — and the prior it supports.
///
/// Three corrections, each forced by what a real history file holds.
///
/// **The close is cross-checked against the ring.** A five-hour occurrence that reached 5%
/// can be stored as 0.00%, when the window expired unused, the provider reported zero without
/// naming a new reset instant, and the close was written from the last poll. The truth is in
/// the ring, and this reading repairs the rows already on disk.
///
/// **A restatement is not an occurrence.** Both weekly windows carry a completed row that
/// closed at a poll instant, not a reset instant, because the provider nudged `resets_at`
/// forward by one second. The row that follows it opens *before* it closed — two occurrences
/// of one window cannot overlap, so the earlier one is the later one, restated, and it is
/// dropped.
///
/// **A window nobody worked in is dropped.** One of the three on this Mac closed at 0.00%:
/// five hours in which nothing happened. The mean of {58, 11, 0} is 23 and the median is 11;
/// a prior built on windows you slept through is a prior about sleeping.
public nonisolated struct WindowLedger: Equatable, Sendable {
    public let observations: [LedgerObservation]

    /// The usable rows, oldest first: distinct occurrences in which work happened.
    public var usable: [LedgerObservation] { observations.filter(\.isUsable) }
    public var usableCount: Int { usable.count }

    /// Reads one window's ledger, correcting each row against the ring beside it.
    public init(window: UsageWindowTrace) {
        let rows = window.completed
        var observations: [LedgerObservation] = []
        observations.reserveCapacity(rows.count)

        // The rows are in order and so is the ring, so one walk over each answers every row.
        // Reading the whole ring per row is sixty-four passes over eight hundred samples for
        // one window, on every poll, and the answer is the same.
        let times = window.sampleTimes
        let values = window.sampleUsedBasisPoints
        var cursor = 0

        for (index, row) in rows.enumerated() {
            while cursor < times.count, times[cursor] < row.openedAt { cursor += 1 }
            var ringMaximum = 0
            var scan = cursor
            while scan < times.count, times[scan] <= row.closedAt {
                ringMaximum = max(ringMaximum, values[scan])
                scan += 1
            }
            let nextOpenedAt = index + 1 < rows.count ? rows[index + 1].openedAt : window.currentOpenedAt
            observations.append(
                LedgerObservation(
                    openedAt: row.opened,
                    closedAt: row.closed,
                    closePercent: usagePercent(
                        fromBasisPoints: max(row.usedBasisPointsAtClose, ringMaximum)
                    ),
                    weeklyCostPercent: row.weeklyCostPercent,
                    isRestatement: nextOpenedAt < row.closedAt
                )
            )
        }
        self.observations = observations
    }

    public init(observations: [LedgerObservation]) {
        self.observations = observations
    }

    /// The most recent usable closes, newest first — what the prior reads.
    public var recentCloses: [Double] {
        usable.suffix(BrainPolicy.ledgerDepth).reversed().map(\.closePercent)
    }
}

/// What the last few windows actually cost: a point, and the spread around it.
public nonisolated struct LedgerPrior: Equatable, Sendable {
    /// The weighted median of the corrected working closes.
    public let landing: Double
    /// The low and high edges at the coverage asked for, or `nil` when the sample is too
    /// small for any interval to be drawn from it at all.
    public let low: Double?
    public let high: Double?
    /// How many occurrences it rests on.
    public let count: Int

    /// The prior over a set of closes, **newest first** — the order the recency weights read.
    ///
    /// `λ^j` over occurrences-ago. At λ = 1 this is a plain quantile.
    public static func make(recentClosesNewestFirst closes: [Double], coverage: Double) -> LedgerPrior? {
        guard !closes.isEmpty else { return nil }
        // Sorting loses the order the weights are about, so the age of each value — its
        // position in the newest-first list — is carried across the sort with it.
        let ordered = closes.enumerated()
            .sorted { $0.element == $1.element ? $0.offset < $1.offset : $0.element < $1.element }
        let sorted = ordered.map(\.element)
        let weights = ordered.map { pow(BrainPolicy.ledgerRecencyLambda, Double($0.offset)) }
        guard let median = EmpiricalQuantile.value(sorted: sorted, weights: weights, p: 0.5) else {
            return nil
        }
        // One occurrence names a level and no spread at all. Answering with a zero-width
        // interval would claim certainty from a single observation; the honest answer is
        // that the prior has no edges and the caller draws the whole line.
        guard closes.count >= 2 else {
            return LedgerPrior(landing: median, low: nil, high: nil, count: closes.count)
        }
        let tail = (1 - coverage) / 2
        return LedgerPrior(
            landing: median,
            low: EmpiricalQuantile.value(sorted: sorted, weights: weights, p: tail),
            high: EmpiricalQuantile.value(sorted: sorted, weights: weights, p: 1 - tail),
            count: closes.count
        )
    }

    /// Blends this account's own prior toward the fleet's, by Bühlmann credibility.
    ///
    /// **The fleet is what makes the credibility measurable.** An account estimated from its own
    /// history alone leaves how much to trust it a guess. This app holds up to five accounts
    /// belonging to the same person doing the same work, so both variances are estimable and `K`
    /// is a measured number: how many completed windows before this account's own history beats
    /// the fleet's average.
    public func credibilityBlended(towards fleet: LedgerPrior?, k: Double?) -> LedgerPrior {
        guard let fleet, let k, k >= 0, !k.isNaN else { return self }
        // An infinite `K` is what `fleetCredibilityConstant` answers when the accounts differ
        // by less than the noise within them. The credibility is then zero and the pooled
        // sample is the whole prior, which is the correct Bühlmann answer and not a fallback.
        let credibility = k.isFinite ? Double(count) / (Double(count) + k) : 0
        func blend(_ own: Double?, _ other: Double?) -> Double? {
            guard let own else { return other }
            guard let other else { return own }
            return credibility * own + (1 - credibility) * other
        }
        return LedgerPrior(
            landing: credibility * landing + (1 - credibility) * fleet.landing,
            low: blend(low, fleet.low),
            high: blend(high, fleet.high),
            count: count
        )
    }

    /// Bühlmann's `K = EPV / VHM`, measured across the accounts of the fleet.
    ///
    /// `nil` when it cannot be measured — one account, or a fleet whose accounts differ by
    /// less than the noise within them. A `VHM` at or below zero says the accounts are
    /// indistinguishable, and the honest response is to answer with the pooled sample rather
    /// than to invent a number that would keep them apart.
    public static func fleetCredibilityConstant(closesPerAccount: [[Double]]) -> Double? {
        let populated = closesPerAccount.filter { $0.count >= 2 }
        guard populated.count >= 2 else { return nil }

        let means = populated.map { $0.reduce(0, +) / Double($0.count) }
        let withinVariances = zip(populated, means).map { values, mean in
            values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        }
        let expectedProcessVariance = withinVariances.reduce(0, +) / Double(withinVariances.count)
        let meanOfMeans = means.reduce(0, +) / Double(means.count)
        let varianceOfMeans = means.reduce(0) { $0 + ($1 - meanOfMeans) * ($1 - meanOfMeans) }
            / Double(means.count - 1)
        let averageCount = Double(populated.reduce(0) { $0 + $1.count }) / Double(populated.count)
        let varianceOfHypotheticalMeans = varianceOfMeans - expectedProcessVariance / averageCount
        guard varianceOfHypotheticalMeans > 0 else { return .infinity }
        return expectedProcessVariance / varianceOfHypotheticalMeans
    }
}
