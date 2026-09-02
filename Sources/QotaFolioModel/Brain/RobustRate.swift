import Foundation

/// The two order-statistic estimators the in-window observation is built from.
///
/// Both are chosen for the same reason: they work at three points and they cannot be moved
/// by one bad reading. The live trace on this Mac contains a −5.00 pp step inside an
/// occurrence, and consumption inside an occurrence cannot fall — so any estimator with a
/// breakdown point of zero produces a negative-rate absurdity the first time a provider
/// refreshes a stale number.
public nonisolated enum RobustRate {
    /// Pool-adjacent-violators: the exact least-squares projection onto the monotone cone.
    ///
    /// O(n), no tuning parameter — which is what makes it usable at n = 3 — and it is what
    /// cleans the physics before anything is measured. Ayer, Brunk, Ewing, Reid & Silverman
    /// (1955); Barlow, Bartholomew, Bremner & Brunk (1972).
    public static func monotoneIncreasingFit(_ values: [Double]) -> [Double] {
        guard values.count > 1 else { return values }
        // Each block is a run of pooled points at their common mean.
        var blockMean: [Double] = []
        var blockCount: [Int] = []
        blockMean.reserveCapacity(values.count)
        blockCount.reserveCapacity(values.count)

        for value in values {
            blockMean.append(value)
            blockCount.append(1)
            while blockMean.count > 1, blockMean[blockMean.count - 2] > blockMean[blockMean.count - 1] {
                let lastMean = blockMean.removeLast()
                let lastCount = blockCount.removeLast()
                let previousMean = blockMean.removeLast()
                let previousCount = blockCount.removeLast()
                let count = previousCount + lastCount
                blockMean.append((previousMean * Double(previousCount) + lastMean * Double(lastCount)) / Double(count))
                blockCount.append(count)
            }
        }

        var fitted: [Double] = []
        fitted.reserveCapacity(values.count)
        for (mean, count) in zip(blockMean, blockCount) {
            fitted.append(contentsOf: repeatElement(mean, count: count))
        }
        return fitted
    }

    /// Sen's form of the Theil–Sen slope: the median of the pairwise slopes, with tied
    /// x-coordinates excluded rather than divided by zero.
    ///
    /// Sen's extension is the one to implement here and the reason is in the data: the
    /// x-coordinate is cumulative *active* hours, so every idle stretch is a tie. Excluding
    /// ties is what makes the answer "percentage points per working hour" instead of per
    /// wall-clock hour.
    ///
    /// Breakdown point 29.3%: one corrupt reading perturbs at most n−1 of the n(n−1)/2
    /// pairwise slopes and cannot move their median. Ordinary least squares has breakdown
    /// zero — on a staircase series, one stale reading moves the fitted slope without bound.
    ///
    /// Returns `nil` when no two points sit at different x, which is the honest answer for a
    /// window nobody has worked in.
    public static func senSlope(x: [Double], y: [Double]) -> Double? {
        guard x.count == y.count, x.count > 1 else { return nil }
        var slopes: [Double] = []
        slopes.reserveCapacity(x.count * (x.count - 1) / 2)
        for i in 0..<(x.count - 1) {
            for j in (i + 1)..<x.count where x[j] > x[i] {
                slopes.append((y[j] - y[i]) / (x[j] - x[i]))
            }
        }
        guard !slopes.isEmpty else { return nil }
        slopes.sort()
        let middle = slopes.count / 2
        return slopes.count.isMultiple(of: 2)
            ? (slopes[middle - 1] + slopes[middle]) / 2
            : slopes[middle]
    }
}
