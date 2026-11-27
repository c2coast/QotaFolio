import Foundation

/// A rate in points an hour, and the hours of clock it was measured over.
struct Rate {
    let perHour: Double
    let hours: Double
}

/// The cumulative at instant x inside poll i's week, straight between polls, with the week's own
/// start at zero. A change across a gap is spread evenly over the gap.
func cumulative(at x: Double, poll i: Int, _ c: [Double], _ m: Meters) -> Double {
    let start = m.reset(i) - secondsPerWeek
    if x <= start { return 0.0 }
    var ta = start, ca = 0.0
    for k in min(m.opens[i], i + 1)..<(i + 1) {
        let tb = m.t[k], cb = c[k]
        if ta <= x && x <= tb {
            return tb > ta ? ca + (cb - ca) * (x - ta) / (tb - ta) : cb
        }
        ta = tb
        ca = cb
    }
    return ca
}

/// Seconds between x0 and poll i when the meter could not be spent. Time at the limit is not a
/// choice not to work; it is demand nobody could see.
///
/// A stretch is blocked from a poll at 100 percent to the next poll, or to the poll's own reset
/// when that comes first: a limit that has reset can be spent again.
func blocked(from x0: Double, poll i: Int, _ meter: Meters.Meter, _ m: Meters) -> Double {
    var total = 0.0
    for k in min(max(0, m.opens[i] - 1), i)..<i {
        let a = max(m.t[k], x0), b = min(m.t[k + 1], m.reset(k))
        if b <= a { continue }
        if m.pinned(meter, k) { total += b - a }
    }
    return total
}

/// The rate of the cumulative from x0 to poll i, with the blocked time taken out of the clock.
/// None when no clock is left.
func rate(from x0: Double, poll i: Int, _ c: [Double], _ meter: Meters.Meter, _ m: Meters) -> Rate? {
    let now = m.t[i]
    let span = now - x0 - blocked(from: x0, poll: i, meter, m)
    if span <= 0 { return nil }
    return Rate(perHour: (c[i] - cumulative(at: x0, poll: i, c, m)) / (span / secondsPerHour), hours: span / secondsPerHour)
}
