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
    /// Zero at every poll when the account has no model week.
    let model: [Double]
    let modelKind: Limit.Kind?
    let resets: [ResetTime]

    init(_ all: [Reading]) {
        // A reading the Engine can place in a week carries the week and the week's reset.
        let readings = all.filter { $0.limit(.week)?.resets != nil }
        // The model's week is the one limit on one model's week that every reading carries.
        let modelKind = readings.first?.limits.map(\.kind).first { kind in
            kind.model != nil && kind.period == .week && readings.allSatisfy { $0.limit(kind) != nil }
        }
        self.readings = readings
        self.modelKind = modelKind
        t = readings.map { $0.at.timeIntervalSince1970 }
        week = readings.map { $0.limit(.week)!.used.value }
        model = readings.map { reading in modelKind.map { reading.limit($0)!.used.value } ?? 0 }
        resets = readings.map { $0.limit(.week)!.resets! }
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
