import Foundation

/// A fall found at poll `index`, against the poll before it.
struct FoundFall {
    let index: Int
    let kind: Fall.Kind
    let givenBackToWeek: Double
    let givenBackToModel: Double
}

/// Every fall inside one week, told apart from the two meters together. A fall across the week's
/// own reset is the scheduled reset, not a banked one.
func findFalls(_ m: Meters) -> [FoundFall] {
    let w = m.week, f = m.model
    var falls: [FoundFall] = []
    for i in m.t.indices.dropFirst() {
        if m.resets[i - 1] != m.resets[i] { continue }
        let dW = w[i] - w[i - 1], dF = f[i] - f[i - 1]
        if dW >= -1 && dF >= -1 { continue }
        let afterModelReset = w[i - 1] - modelShareOfWeek * f[i - 1]
        if w[i] <= 5 || w[i] < afterModelReset - 5 {
            falls.append(FoundFall(index: i, kind: .full, givenBackToWeek: w[i - 1], givenBackToModel: f[i - 1]))
        } else if dF < -1 {
            falls.append(FoundFall(index: i, kind: .model, givenBackToWeek: modelShareOfWeek * f[i - 1], givenBackToModel: f[i - 1]))
        } else {
            falls.append(FoundFall(index: i, kind: .unexplained, givenBackToWeek: w[i - 1] - w[i], givenBackToModel: 0.0))
        }
    }
    return falls
}

/// One meter's ledger at each poll: the points given back so far this week, and the cumulative,
/// which is the reading plus those points. The cumulative only rises inside a week, and it measures
/// work done, which the reading no longer does after a banked reset.
struct Ledger {
    let givenBack: [Double]
    let cumulative: [Double]

    init(_ m: Meters, _ falls: [FoundFall], _ meter: Meters.Meter) {
        let used = m.used(meter)
        var byIndex: [Int: Double] = [:]
        for fall in falls {
            byIndex[fall.index] = meter == .week ? fall.givenBackToWeek : fall.givenBackToModel
        }
        var givenBack: [Double] = [], cumulative: [Double] = []
        var weekOf: ResetTime?
        var restored = 0.0
        for i in m.t.indices {
            if m.resets[i] != weekOf {
                weekOf = m.resets[i]
                restored = 0.0
            }
            restored += byIndex[i] ?? 0.0
            givenBack.append(restored)
            cumulative.append(used[i] + restored)
        }
        self.givenBack = givenBack
        self.cumulative = cumulative
    }
}
