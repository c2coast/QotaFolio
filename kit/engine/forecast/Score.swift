import Foundation

/// What then happened to the room a limit had at a poll.
public enum Outcome: Hashable, Sendable {
    /// The limit, or the week above it, was at 100 percent at the poll.
    case spent
    /// The work done after the poll used the room up. The moment is placed straight between the two
    /// polls around it; `gapHours` is how far apart they were.
    case ranOut(at: Date, gapHours: Double)
    /// The week reset first, with this percent used.
    case lasted(landing: Double)
    /// The week has not ended in the record and the room is not used up yet.
    case unknown
}

extension Forecast {
    /// What then happened at each poll, for one limit. Work is measured with the points falls gave
    /// back, so a banked reset spent later does not hide work that was done. The record ends at
    /// `recordEnd`, the last poll of any account.
    public func outcomes(of kind: Limit.Kind, recordEnd: Date) -> [Outcome] {
        let t = polls.map { $0.reading.at.timeIntervalSince1970 }
        let reset = polls.map { $0.resets.instant.timeIntervalSince1970 }
        let used = polls.map { $0.reading.limit(kind)?.used.value ?? 0 }
        let c = polls.indices.map { used[$0] + (polls[$0].givenBack[kind] ?? 0) }
        let end = recordEnd.timeIntervalSince1970
        return polls.indices.map { i in
            let week = polls[i].reading.limit(.week)?.used.value ?? 0
            if week >= 100 || used[i] >= 100 { return .spent }
            let h = 100 - used[i]
            for j in (i + 1)..<t.count {
                if t[j] >= reset[i] { break }
                if c[j] - c[i] >= h - 1e-9 {
                    let doneBefore = c[j - 1] - c[i]
                    let fraction = c[j] > c[j - 1] ? (h - doneBefore) / (c[j] - c[j - 1]) : 1.0
                    let at = t[j - 1] + fraction * (t[j] - t[j - 1])
                    return .ranOut(at: Date(timeIntervalSince1970: at), gapHours: (t[j] - t[j - 1]) / secondsPerHour)
                }
            }
            if reset[i] <= end, let j = t.lastIndex(where: { $0 < reset[i] }) {
                return .lasted(landing: used[i] + c[j] - c[i])
            }
            return .unknown
        }
    }
}

/// How often the forecast for one limit, or the account's forecast, was right, scored poll by poll
/// as the prototype scored it.
public struct Score: Hashable, Sendable {
    /// Polls where the verdict spoke, and where it stayed silent. Spent polls count in neither.
    public let spoken: Int
    public let silent: Int
    /// Spoken polls whose outcome is known, and those whose verdict had the outcome's kind.
    public let judged: Int
    public let right: Int
    /// Changes of kind between one spoken verdict and the next, inside one account's week.
    public let flips: Int
    /// For each poll that said "runs out" and did run out: how far off the time was, in hours.
    public let timingErrors: [Double]

    /// Run-outs said and seen that named the limit that ran out first. For one limit it is every
    /// timed run-out; for the account it is the account's first limit.
    public let named: Int

    /// The score of one limit.
    public init(of forecasts: [Forecast], limit kind: Limit.Kind, recordEnd: Date) {
        self.init(calls: forecasts.map { forecast in
            zip(forecast.polls, forecast.outcomes(of: kind, recordEnd: recordEnd)).compactMap { poll, outcome in
                guard let verdict = poll.verdicts[kind], verdict != .spent, outcome != .spent else { return nil }
                return Call(week: poll.resets, said: verdict.claim(kind), happened: outcome.claim(kind))
            }
        })
    }

    /// The score of the calls, one array for each account, in time order.
    init(calls accounts: [[Call]]) {
        var spoken = 0, silent = 0, judged = 0, right = 0, named = 0, flips = 0
        var errors: [Double] = []
        for calls in accounts {
            var previous: Bool?, week: ResetTime?
            for call in calls {
                if call.week != week {
                    previous = nil
                    week = call.week
                }
                guard let said = call.said else {
                    silent += 1
                    continue
                }
                spoken += 1
                if let previous, previous != said.runsOut { flips += 1 }
                previous = said.runsOut
                guard let happened = call.happened else { continue }
                judged += 1
                if said.runsOut == happened.runsOut { right += 1 }
                if case .runsOut(let at, let limit) = said, case .runsOut(let then, let first) = happened {
                    errors.append(abs((at.timeIntervalSince1970 - then.timeIntervalSince1970) / secondsPerHour))
                    if limit == first { named += 1 }
                }
            }
        }
        self.spoken = spoken
        self.silent = silent
        self.judged = judged
        self.right = right
        self.named = named
        self.flips = flips
        timingErrors = errors
    }

    /// The median timing error in hours, the two middle errors averaged when their count is even.
    /// None when no run-out was timed.
    public var medianError: Double? {
        guard !timingErrors.isEmpty else { return nil }
        let sorted = timingErrors.sorted()
        let k = Double(sorted.count - 1) * 0.5
        let lo = Int(k.rounded(.down)), hi = Int(k.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (k - Double(lo))
    }
}

/// One poll the score counts: what the forecast said and what then happened. A poll that was
/// spent, by the forecast or by what happened, is not a call.
struct Call {
    /// The week the poll belongs to. Flips are counted inside one week.
    let week: ResetTime
    /// None when the forecast was silent.
    let said: Claim?
    /// None when what happened is not known yet.
    let happened: Claim?
}

/// That a limit runs out, and when; or that it lasts, which for the account means the week does.
enum Claim {
    case runsOut(at: Date, limit: Limit.Kind)
    case lasts

    var runsOut: Bool {
        if case .runsOut = self { true } else { false }
    }
}

private extension Verdict {
    /// What a verdict that speaks claims. None for one that does not speak.
    func claim(_ kind: Limit.Kind) -> Claim? {
        switch self {
        case .runsOut(let at, _, _): .runsOut(at: at, limit: kind)
        case .lasts: .lasts
        case .spent, .silent: nil
        }
    }
}

private extension Outcome {
    /// What happened, when it is known.
    func claim(_ kind: Limit.Kind) -> Claim? {
        switch self {
        case .ranOut(let at, _): .runsOut(at: at, limit: kind)
        case .lasted: .lasts
        case .spent, .unknown: nil
        }
    }
}
