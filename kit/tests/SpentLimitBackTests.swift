import Foundation
import Kit
import Testing

/// "A spent limit is back", the alert's condition, on the owner's readings in UTC.
@Suite("A spent limit is back")
struct SpentLimitBackTests {
    /// Every reading of the record that found a limit back from 100, read off the raw file: three
    /// weeks back at their resets, two weeks a banked reset brought back, and Fable back once at its
    /// reset and once by a banked reset.
    @Test("The record's seven, each once, and none for a limit that was not spent")
    func theRecord() {
        let seen = Record.accounts.flatMap { readings in
            readings.indices.flatMap { SpentLimitBack.newest(in: readings[...$0]) }
        }.map { "\($0.account.rawValue) \($0.limit.model ?? "week") \(Record.minute($0.spentUntil.instant)) \($0.how)" }
        #expect(seen == [
            "A week Wed 12 Nov 21:00 reset",
            "A week Wed 19 Nov 21:00 banked",
            "B week Fri 14 Nov 13:00 reset",
            "B Fable Fri 14 Nov 13:00 reset",
            "B Fable Fri 21 Nov 13:00 banked",
            "B week Fri 21 Nov 13:00 banked",
            "B week Fri 21 Nov 13:00 reset",
        ])
    }

    /// B's week and Fable came back at Fri 14 Nov 13:15:17. The reading after it, 13:30:20, finds
    /// nothing back.
    @Test("The reading that finds a limit back, and not the one after it")
    func oneEvent() throws {
        let readings = Record.accounts[1]
        let k = try #require(readings.firstIndex { $0.at == Record.moment(14, 13, 15, 17) })
        let reset = ResetTime(Record.moment(14, 13, 0))
        #expect(SpentLimitBack.newest(in: readings[...k])
            == [SpentLimitBack(account: AccountID("B"), limit: .week, spentUntil: reset, how: .reset),
                SpentLimitBack(account: AccountID("B"), limit: Record.fable, spentUntil: reset, how: .reset)])
        #expect(SpentLimitBack.newest(in: readings[...(k + 1)]).isEmpty)
    }

    /// The week spent at 100 and resetting Wed 21:00, read at 20:57 with the session. The trace
    /// samples the week every quarter-hour and the session at every poll, so the poll of 21:00
    /// keeps the session alone, and the poll of 21:03 reads the week again, at 0 with next week's
    /// reset. That poll finds the week back at its reset; the session-only reading finds nothing.
    @Test("A spent week is back at the next reading that carries it, past a reading without it")
    func pastAReadingWithoutIt() {
        let session = Limit.Kind(model: nil, period: .session), reset = ResetTime(Record.moment(26, 21, 0))
        func reading(_ hour: Int, _ minute: Int, _ limits: [Limit]) -> Reading {
            Reading(account: AccountID("S"), at: Record.moment(26, hour, minute), limits: limits)
        }
        let open = Limit(kind: session, used: Percent(0)!, resets: ResetTime(Record.moment(27, 1, 0)))
        let readings = [
            reading(20, 57, [Limit(kind: .week, used: Percent(100)!, resets: reset), open]),
            reading(21, 0, [open]),
            reading(21, 3, [Limit(kind: .week, used: Percent(0)!, resets: ResetTime(Record.moment(33, 21, 0))), open]),
        ]
        #expect(SpentLimitBack.newest(in: readings[...1]).isEmpty)
        #expect(SpentLimitBack.newest(in: readings) == [SpentLimitBack(account: AccountID("S"), limit: .week, spentUntil: reset, how: .reset)])
        let nearly = [Reading(account: AccountID("S"), at: Record.moment(26, 20, 57), limits: [Limit(kind: .week, used: Percent(99)!, resets: reset)])]
        #expect(SpentLimitBack.newest(in: nearly + readings[1...]).isEmpty)
    }

    /// Two of the record's events in words, said at the reading that found them, worked by hand: B's
    /// week back at its reset of Fri 14 Nov 13:00, said that afternoon, and A's week back by the
    /// banked reset before its reset of Wed 19 Nov 21:00, said on that Tuesday.
    @Test("The alert says the limit, how it came back, and its day")
    func sentence() {
        let friday = TimeWords(timeZone: Record.zone, now: Record.moment(14, 13, 15, 17))
        let week = SpentLimitBack(account: AccountID("B"), limit: .week, spentUntil: ResetTime(Record.moment(14, 13, 0)), how: .reset)
        #expect(week.sentence(account: "Work", words: friday) == "Work's week is back. It reset Fri 13:00.")
        let fable = SpentLimitBack(account: AccountID("B"), limit: Record.fable, spentUntil: ResetTime(Record.moment(14, 13, 0)), how: .reset)
        #expect(fable.sentence(account: "Work", words: friday) == "Work's Fable week is back. It reset Fri 13:00.")
        let tuesday = TimeWords(timeZone: Record.zone, now: Record.moment(18, 9, 0))
        let banked = SpentLimitBack(account: AccountID("A"), limit: .week, spentUntil: ResetTime(Record.moment(19, 21, 0)), how: .banked)
        #expect(banked.sentence(account: "Personal", words: tuesday)
            == "Personal's week is back early. A banked reset gave its points back before Wed 21:00.")
    }
}
