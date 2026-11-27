import Foundation
import Kit
import Testing

/// Version 1.0.0 spaces each limit's samples on its own, so a poll that missed Fable leaves the
/// week and Fable sampled at other seconds from then on. The Engine reads the model's week from the
/// readings that carry it.
@Suite("A model's week on some readings")
struct ModelWeekTests {
    /// The readings of the record where a fall ends, the week's own resets included: a fall is told
    /// from both meters at the poll before it and at it, so those polls keep their Fable.
    static let falls = [[27, 166, 186, 222, 237], [87, 135, 153, 283]]

    @Test("Fable missing from every tenth reading leaves every week verdict as it was", arguments: [0, 1])
    func weekUnchanged(account: Int) throws {
        let readings = Record.accounts[account]
        let stripped = Set(stride(from: 5, to: readings.count, by: 10).filter { i in
            !Self.falls[account].contains(i) && !Self.falls[account].contains(i + 1)
        })
        let without = readings.enumerated().map { i, reading in
            stripped.contains(i) ? Reading(account: reading.account, at: reading.at, limits: reading.limits.filter { $0.kind == .week }) : reading
        }
        let whole = [Record.a, Record.b][account], forecast = Forecast(readings: without)
        #expect(stripped.count >= 25)
        #expect(forecast.polls.count == whole.polls.count)
        for (i, (poll, intact)) in zip(forecast.polls, whole.polls).enumerated() {
            #expect(poll.verdicts[.week] == intact.verdicts[.week], "\(Record.minute(poll.reading.at))")
            #expect(poll.givenBack[.week] == intact.givenBack[.week], "\(Record.minute(poll.reading.at))")
            if stripped.contains(i) {
                #expect(poll.reading.limit(Record.fable) == nil)
                #expect(poll.used[Record.fable] == readings[i - 1].limit(Record.fable)?.used, "\(Record.minute(poll.reading.at))")
                #expect(poll.verdicts[Record.fable] != nil)
            }
        }
    }

    /// A made-up week from Tue 2 Dec 09:30 to Tue 9 Dec 09:30. The week and Fable are read together
    /// at 10:00 and 13:00; between, the week alone at 11:00 and 12:00, and Fable alone at 11:00:30
    /// and 12:00:30.
    ///
    /// At the week's poll of 12:00 the week reads 18, and Fable reads 20, its reading of 11:00:30.
    /// Three hours back is before the week began, so the burn's clock is 2.5 hours from 09:30, and
    /// 18 points of rise make it speak: 18 / 2.5 = 7.2 points an hour.
    /// Fable takes it at the week's mix, 20 / 18: 8.0 points an hour, so 80 points run out at 22:00.
    /// The step: 19.5 at 19 / 2.5 x 20 / 18 = 8.44 runs out 21:32; 20.5 at 17 / 2.5 x 20 / 18 = 7.56
    /// runs out 22:31. Both run out, so it speaks.
    @Test("Fable is read from the readings that carry it, at other seconds than the week")
    func otherSeconds() throws {
        let day = Self.day(2), reset = ResetTime(day + 9.5 * 3600 + 7 * 86400)
        func reading(_ hours: Double, week: Double?, fable: Double?) -> Reading {
            var limits: [Limit] = []
            if let week { limits.append(Limit(kind: .week, used: Percent(week)!, resets: reset)) }
            if let fable { limits.append(Limit(kind: Record.fable, used: Percent(fable)!, resets: reset)) }
            return Reading(account: AccountID("M"), at: day + hours * 3600, limits: limits)
        }
        let forecast = Forecast(readings: [
            reading(10, week: 10, fable: 10), reading(11, week: 14, fable: nil), reading(11 + 30 / 3600.0, week: nil, fable: 20),
            reading(12, week: 18, fable: nil), reading(12 + 30 / 3600.0, week: nil, fable: 30), reading(13, week: 22, fable: 40),
        ])
        #expect(forecast.polls.map { Record.minute($0.reading.at).suffix(5) } == ["10:00", "11:00", "12:00", "13:00"])
        let poll = forecast.polls[2]
        #expect(poll.used[Record.fable] == Percent(20))
        guard case .runsOut(let at, let rate, let speed) = poll.verdicts[Record.fable] else {
            Issue.record("expected Fable to run out, got \(String(describing: poll.verdicts[Record.fable]))")
            return
        }
        #expect(at == day + 22 * 3600)
        #expect(abs(rate - 8.0) < 1e-9)
        #expect(speed == .burn)
    }

    /// Fable's last reading of a week says nothing of the next: a new week opens at zero.
    @Test("A week's first poll without Fable has no Fable verdict")
    func notCarriedIntoTheNextWeek() {
        let day = Self.day(2), first = ResetTime(day + 12 * 3600), second = ResetTime(day + 12 * 3600 + 7 * 86400)
        let forecast = Forecast(readings: [
            Reading(account: AccountID("M"), at: day + 11 * 3600, limits: [
                Limit(kind: .week, used: Percent(60)!, resets: first), Limit(kind: Record.fable, used: Percent(70)!, resets: first),
            ]),
            Reading(account: AccountID("M"), at: day + 13 * 3600, limits: [Limit(kind: .week, used: Percent(2)!, resets: second)]),
        ])
        #expect(forecast.polls.count == 2)
        #expect(forecast.polls[1].used[Record.fable] == nil)
        #expect(forecast.polls[1].verdicts[Record.fable] == nil)
        #expect(forecast.falls.isEmpty)
    }

    /// Midnight UTC of a day of December 2025.
    static func day(_ n: Int) -> Date {
        Record.calendar.date(from: DateComponents(year: 2025, month: 12, day: n))!
    }
}
