import Foundation

/// When the limit reaches 100 percent at a rate, in seconds since 1970. None at a rate that does
/// not rise.
private func full(now: Double, used u: Double, perHour: Double) -> Double? {
    let h = 100 - u
    return perHour <= 0 ? nil : now + h / perHour * secondsPerHour
}

/// The verdict at a rate: when 100 percent comes before the reset, or where the limit lands.
func verdict(now: Double, reset: Double, used u: Double, perHour: Double, speed: Verdict.Speed) -> Verdict {
    guard let eta = full(now: now, used: u, perHour: perHour) else { return .lasts(landing: u, rate: perHour, speed: speed) }
    if eta < reset { return .runsOut(at: Date(timeIntervalSince1970: eta), rate: perHour, speed: speed) }
    return .lasts(landing: u + perHour * (reset - now) / secondsPerHour, rate: perHour, speed: speed)
}

/// Silent when one whole percent of the reading, with the rate at the matching end of its own
/// step, changes what the verdict says.
func withStep(now: Double, reset: Double, used u: Double, perHour: Double, low: Double, high: Double,
              speed: Verdict.Speed) -> Verdict {
    let lower = full(now: now, used: max(0, u - 0.5), perHour: high).map { $0 < reset } ?? false
    let upper = full(now: now, used: min(100, u + 0.5), perHour: max(0, low)).map { $0 < reset } ?? false
    return lower != upper ? .silent(.insideOneStep) : verdict(now: now, reset: reset, used: u, perHour: perHour, speed: speed)
}

/// The two speeds of one meter at poll i, on the cumulative c: the last three hours' burn while
/// the meter moves two whole steps or more in them, else the whole week's unblocked pace. The
/// rate is scaled by `mix`, the share of the meter's work in the work measured.
///
/// None when neither speed has a clock.
private func twoSpeed(poll i: Int, used u: Double, measuring c: [Double], _ meter: Meters.Meter, mix: Double?,
                      _ m: Meters) -> Verdict? {
    let now = m.t[i], reset = m.reset(i), start = reset - secondsPerWeek
    let whole = rate(from: start, poll: i, c, meter, m)
    let burn = rate(from: max(start, now - 3 * secondsPerHour), poll: i, c, meter, m)
    if let burn, burn.hours >= 1.0, burn.perHour * burn.hours >= 2 {
        let points = burn.perHour * burn.hours
        if let mix {
            return withStep(now: now, reset: reset, used: u, perHour: burn.perHour * mix,
                            low: (points - 1) / burn.hours * mix, high: (points + 1) / burn.hours * mix, speed: .burn)
        }
        return withStep(now: now, reset: reset, used: u, perHour: burn.perHour,
                        low: (points - 1) / burn.hours, high: (points + 1) / burn.hours, speed: .burn)
    }
    if let whole {
        if let mix {
            return withStep(now: now, reset: reset, used: u, perHour: whole.perHour * mix,
                            low: (whole.perHour - 0.5 / whole.hours) * mix, high: (whole.perHour + 0.5 / whole.hours) * mix,
                            speed: .weekPace)
        }
        return withStep(now: now, reset: reset, used: u, perHour: whole.perHour,
                        low: whole.perHour - 0.5 / whole.hours, high: whole.perHour + 0.5 / whole.hours, speed: .weekPace)
    }
    return nil
}

/// The verdict for one meter at poll i.
///
/// The model's week takes its speed from the week: how fast comes from the week's two speeds, and
/// what the work is made of comes from the week's own mix, the model's cumulative over the week's.
/// So the week's ledger is worked out first.
func verdict(poll i: Int, _ meter: Meters.Meter, _ ledger: Ledger, week weekLedger: Ledger, _ m: Meters) -> Verdict {
    let u = m.used(meter)[i]
    if u >= 100 || m.week[i] >= 100 { return .spent }
    if u <= 0 { return .silent(.notStarted) }
    let c = ledger.cumulative, cw = weekLedger.cumulative
    if meter == .model, cw[i] > 0,
       let mixed = twoSpeed(poll: i, used: u, measuring: cw, .week, mix: c[i] / cw[i], m) {
        return mixed
    }
    return twoSpeed(poll: i, used: u, measuring: c, meter, mix: nil, m) ?? .silent(.noClockYet)
}
