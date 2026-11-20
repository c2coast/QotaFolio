import Foundation

extension Score {
    /// The score of the account's forecast: what was said against the first limit that ran out.
    ///
    /// The forecast "spent" and "the model's week is spent" are not calls, nor is a poll where
    /// either limit was spent. "No use yet" and "too early to say" are silent. What happened is the
    /// earliest limit to run out, the model's week on a tie, as the pace prototype has it; else the
    /// week lasted, once both outcomes are known.
    public init(accountsOf forecasts: [Forecast], recordEnd: Date) {
        self.init(calls: forecasts.map { forecast in
            let model = forecast.polls.first?.verdicts.keys.first { $0 != .week }
            let week = forecast.outcomes(of: .week, recordEnd: recordEnd)
            let modelOutcomes = model.map { forecast.outcomes(of: $0, recordEnd: recordEnd) }
            return forecast.polls.indices.compactMap { i in
                let outcomes = [(Limit.Kind.week, week[i])] + (model.map { [($0, modelOutcomes![i])] } ?? [])
                if outcomes.contains(where: { $0.1 == .spent }) { return nil }
                let said: Claim?
                switch AccountForecast(poll: forecast.polls[i]) {
                case .spent, .modelSpent: return nil
                case .notStarted, .silent: said = nil
                case .runsOut(let first, let at, _, _): said = .runsOut(at: at, limit: first)
                case .lasts: said = .lasts
                }
                return Call(week: forecast.polls[i].resets, said: said, happened: Self.first(outcomes))
            }
        })
    }

    /// The first limit to run out, the model's week on a tie; else that the week lasted. None while
    /// either outcome is unknown and nothing has run out.
    private static func first(_ outcomes: [(Limit.Kind, Outcome)]) -> Claim? {
        let ranOut = outcomes.compactMap { kind, outcome in
            if case .ranOut(let at, _) = outcome { (at, kind) } else { nil }
        }
        if let (at, kind) = ranOut.min(by: { $0.0 < $1.0 || ($0.0 == $1.0 && $0.1 != .week) }) {
            return .runsOut(at: at, limit: kind)
        }
        return outcomes.contains { $0.1 == .unknown } ? nil : .lasts
    }
}
