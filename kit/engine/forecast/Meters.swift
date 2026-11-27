import Foundation

let secondsPerHour = 3600.0
let secondsPerWeek = 7 * 86400.0

/// One model-week point is half a weekly point: the model may use at most half of the week. On
/// the owner's recorded weeks no poll broke this.
let modelShareOfWeek = 0.5

/// The two meters of one account as the method reads them: at each poll, its time in seconds since
/// 1970, the week's percent used, the model week's percent used, and the week's reset in force.
///
/// Times stay in seconds since 1970, because the method's arithmetic is done there.
struct Meters {
    enum Meter { case week, model }

    let readings: [Reading]
    let t: [Double]
    let week: [Double]
    /// The model's week as last read at each poll: its latest reading at or before the poll, in the
    /// poll's own week. None where it has not been read this week, and at every poll of an account
    /// with no model's week.
    let modelRead: [Percent?]
    /// The model's week at each poll, zero where it has not been read this week.
    let model: [Double]
    let modelKind: Limit.Kind?
    let resets: [ResetTime]
    /// For each poll, the first poll at or after its week's start. The method reads nothing of a
    /// week before it but the poll just before, so a verdict's cost is the week's, not the history's.
    let opens: [Int]

    /// The readings in time order. A reading without the week is no poll, but it still tells the
    /// model's week, because a limit can be sampled at other seconds than the week.
    init(_ all: [Reading]) {
        // A reading the Engine can place in a week carries the week and the week's reset.
        let readings = all.filter { $0.limit(.week)?.resets != nil }
        // The model's week is the first limit on one model's week that any reading carries.
        let modelKind = all.lazy.flatMap(\.limits).map(\.kind).first { $0.model != nil && $0.period == .week }
        var modelRead: [Percent?] = []
        var latest: (at: Date, used: Percent)?
        var next = all.startIndex
        for reading in readings {
            while next < all.endIndex, all[next].at <= reading.at {
                if let kind = modelKind, let limit = all[next].limit(kind) { latest = (all[next].at, limit.used) }
                next += 1
            }
            let start = min(reading.limit(.week)!.resets!.instant - secondsPerWeek, reading.at)
            modelRead.append(latest.flatMap { $0.at >= start ? $0.used : nil })
        }
        self.readings = readings
        self.modelKind = modelKind
        self.modelRead = modelRead
        let times = readings.map { $0.at.timeIntervalSince1970 }
        t = times
        week = readings.map { $0.limit(.week)!.used.value }
        model = modelRead.map { $0?.value ?? 0 }
        resets = readings.map { $0.limit(.week)!.resets! }
        opens = resets.map { reset in
            let start = reset.instant.timeIntervalSince1970 - secondsPerWeek
            var low = 0, high = times.count
            while low < high {
                let mid = (low + high) / 2
                if times[mid] < start { low = mid + 1 } else { high = mid }
            }
            return low
        }
    }

    func used(_ meter: Meter) -> [Double] {
        switch meter {
        case .week: week
        case .model: model
        }
    }

    /// The reset in force at poll i, in seconds since 1970.
    func reset(_ i: Int) -> Double {
        resets[i].instant.timeIntervalSince1970
    }

    /// Whether the meter could not be spent between poll k and the next: it, or the week above
    /// it, read 100 percent at poll k.
    func pinned(_ meter: Meter, _ k: Int) -> Bool {
        used(meter)[k] >= 100 || week[k] >= 100
    }
}
