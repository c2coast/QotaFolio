import Foundation

extension AccountForecast {
    /// The account's forecast at one poll, from its two limits' verdicts, by the chart page's rule.
    ///
    /// In order: a spent week; nothing used; a spent model's week; a silent week while the model's
    /// week does not run out; then the limit that runs out first, the week on a tie; else the week
    /// lasts. When one limit is silent, the forecast still speaks of the other. It speaks at the
    /// week's speed when the week has one, and else at the model's week's.
    public init(poll: Forecast.Poll) {
        let model = poll.verdicts.keys.first { $0 != .week }
        let week = poll.verdicts[.week] ?? .silent(.noClockYet)
        let modelVerdict = model.flatMap { poll.verdicts[$0] }
        let weekUsed = poll.reading.limit(.week)?.used.value ?? 0
        let modelUsed = model.flatMap { poll.reading.limit($0)?.used.value } ?? 0

        if weekUsed >= 100 {
            self = .spent
        } else if weekUsed <= 0 && modelUsed <= 0 {
            self = .notStarted
        } else if modelUsed >= 100 {
            self = .modelSpent(week: week)
        } else if let at = week.runsOutAt, let speed = week.speed, modelVerdict?.runsOutAt.map({ at <= $0 }) ?? true {
            self = .runsOut(first: .week, at: at, speed: speed, other: modelVerdict)
        } else if let model, let at = modelVerdict?.runsOutAt, let speed = week.speed ?? modelVerdict?.speed {
            self = .runsOut(first: model, at: at, speed: speed, other: week)
        } else if case .lasts(let landing, _, let speed) = week {
            self = .lasts(landing: landing, modelLanding: modelVerdict?.landing, speed: speed)
        } else {
            // The week is silent here: it is not spent, and it does not run out or last.
            self = .silent
        }
    }
}

extension Verdict {
    /// When the limit runs out, for a verdict that says it does.
    var runsOutAt: Date? {
        if case .runsOut(let at, _, _) = self { at } else { nil }
    }

    /// Where the limit lands at its reset, for a verdict that says it lasts.
    var landing: Double? {
        if case .lasts(let landing, _, _) = self { landing } else { nil }
    }

    /// The speed that spoke, for a verdict that speaks.
    var speed: Speed? {
        switch self {
        case .runsOut(_, _, let speed), .lasts(_, _, let speed): speed
        case .spent, .silent: nil
        }
    }
}
