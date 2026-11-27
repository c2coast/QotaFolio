import Foundation

extension Forecast {
    /// The forecast for one account, from its readings in time order.
    ///
    /// The method is "two-speed": the last three hours' burn, with the points of banked resets
    /// added back, says when a limit runs out; when the meter is quiet, the whole week's pace
    /// decides; inside one whole-percent step it stays silent. The model's week takes its speed
    /// from the week, scaled by the week's own mix of work.
    ///
    /// A reading without the week, or without the week's reset, cannot be placed in a week and is
    /// no poll. The week and the model's week get verdicts; a limit of any other period gets none.
    /// The model's week is read from every reading that carries it, so a poll that did not read it
    /// takes its latest reading of the week, and a poll before its first reading of the week has
    /// no verdict for it.
    public init(readings: [Reading]) {
        let m = Meters(readings)
        let found = findFalls(m)
        let weekLedger = Ledger(m, found, .week)
        let model = m.modelKind.map { ($0, Ledger(m, found, .model)) }

        let polls = m.readings.indices.map { i in
            var verdicts: [Limit.Kind: Verdict] = [.week: verdict(poll: i, .week, weekLedger, week: weekLedger, m)]
            var givenBack: [Limit.Kind: Double] = [.week: weekLedger.givenBack[i]]
            var used: [Limit.Kind: Percent] = [.week: m.readings[i].limit(.week)!.used]
            if let (kind, ledger) = model, let read = m.modelRead[i] {
                verdicts[kind] = verdict(poll: i, .model, ledger, week: weekLedger, m)
                givenBack[kind] = ledger.givenBack[i]
                used[kind] = read
            }
            return Poll(reading: m.readings[i], resets: m.resets[i], used: used, verdicts: verdicts, givenBack: givenBack)
        }
        let falls = found.map { fall in
            var givenBack: [Limit.Kind: Double] = [.week: fall.givenBackToWeek]
            if let kind = m.modelKind { givenBack[kind] = fall.givenBackToModel }
            return Fall(kind: fall.kind, before: m.readings[fall.index - 1], after: m.readings[fall.index], givenBack: givenBack)
        }
        self.init(polls: polls, falls: falls)
    }
}
