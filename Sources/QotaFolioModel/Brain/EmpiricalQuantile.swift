import Foundation

/// Sample quantiles, Hyndman & Fan type 8.
///
/// Type 8 is the authors' own recommendation — its plotting position `(k − 1/3)/(n + 1/3)`
/// makes it "approximately median-unbiased regardless of distribution" (Hyndman & Fan, 1996,
/// *The American Statistician* 50(4):361–365). Type 7 is what NumPy and R hand you by
/// default, it is mode-based and distribution-dependent, and at the sample sizes here — nine
/// completed windows, nineteen — the difference is not small.
public nonisolated enum EmpiricalQuantile {
    /// The quantile of a sorted sample, every observation counting once.
    public static func value(sorted values: [Double], p: Double) -> Double? {
        value(sorted: values, weights: nil, p: p)
    }

    /// The quantile of a sorted sample under weights.
    ///
    /// The weights carry recency: a person's rhythm drifts, so an occurrence four windows ago
    /// speaks more quietly than the one that just closed. The weights are normalised to sum
    /// to `n`, so at equal weights every plotting position is exactly type 8's and λ = 1 is a
    /// plain quantile. That is what makes the recency constant a dial rather than a
    /// dependency.
    public static func value(sorted values: [Double], weights: [Double]?, p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        guard values.count > 1 else { return values[0] }
        let count = Double(values.count)

        var normalised = weights ?? [Double](repeating: 1, count: values.count)
        guard normalised.count == values.count else { return nil }
        let total = normalised.reduce(0, +)
        guard total > 0 else { return nil }
        for index in normalised.indices { normalised[index] *= count / total }

        // Type 8's plotting position, written over cumulative weight so that unit weights
        // reproduce it exactly: (k − 1/3)/(n + 1/3).
        var positions: [Double] = []
        positions.reserveCapacity(values.count)
        var cumulative = 0.0
        for weight in normalised {
            cumulative += weight
            positions.append((cumulative - weight / 3) / (count + 1.0 / 3.0))
        }

        let target = min(max(p, 0), 1)
        if target <= positions[0] { return values[0] }
        if target >= positions[positions.count - 1] { return values[values.count - 1] }
        for index in 1..<positions.count where target <= positions[index] {
            let span = positions[index] - positions[index - 1]
            guard span > 0 else { return values[index] }
            let fraction = (target - positions[index - 1]) / span
            return values[index - 1] + fraction * (values[index] - values[index - 1])
        }
        return values[values.count - 1]
    }
}

/// A random source that gives the same answer twice.
///
/// The band is resampled, and a band that shimmers between two polls that learned nothing is
/// a band nobody can read. The seed is derived from the occurrence, so the picture is stable
/// while the occurrence is, and is redrawn when a new one opens. SplitMix64 — Steele, Lea &
/// Flood, OOPSLA 2014 — because it is four lines and has no state to get wrong.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
