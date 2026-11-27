import Foundation
import Kit
import Testing

/// "A spent limit is back", the alert's condition, on the owner's readings in UTC.
@Suite("A spent limit is back")
struct SpentLimitBackTests {
    /// Every pair of consecutive readings of the record where a limit read 100 and then less, read
    /// off the raw file: three weeks back at their resets, two weeks a banked reset brought back,
    /// and Fable back once at its reset and once by a banked reset.
    @Test("The record's seven, each once, and none for a limit that was not spent")
    func theRecord() {
        let seen = Record.accounts.flatMap { readings in
            zip(readings, readings.dropFirst()).flatMap { SpentLimitBack.between($0, $1) }
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

    /// B's week came back at Fri 14 Nov 13:15:17. The account now carries the event from that
    /// reading until the next, the same value each time, so the app shows it once; at the next
    /// reading, 13:30:20, it is gone.
    @Test("The account now carries one event, the same value until the next reading")
    func oneEvent() throws {
        let words = { (at: Date) in TimeWords(calendar: Record.calendar, now: at) }
        let at = try #require(AccountNow(readings: Record.accounts[1], words: words(Record.moment(14, 13, 15, 17))))
        let later = try #require(AccountNow(readings: Record.accounts[1], words: words(Record.moment(14, 13, 29))))
        let next = try #require(AccountNow(readings: Record.accounts[1], words: words(Record.moment(14, 13, 30, 20))))
        let reset = ResetTime(Record.moment(14, 13, 0))
        #expect(at.back == [SpentLimitBack(account: AccountID("B"), limit: .week, spentUntil: reset, how: .reset),
                            SpentLimitBack(account: AccountID("B"), limit: Record.fable, spentUntil: reset, how: .reset)])
        #expect(later.back == at.back)
        #expect(next.back.isEmpty)
    }

    /// A five-hour window spent at 100 and resetting at 14:00. A reading at 13:30 that does not
    /// carry it says nothing; one at 14:10 that does not carry it finds it back at its reset. One at
    /// 99 is not spent, and its reset brings nothing back.
    @Test("A spent window the next reading does not carry is back once its reset has passed")
    func absentAfterItsReset() {
        let session = Limit.Kind(model: nil, period: .session), reset = ResetTime(Record.moment(26, 14, 0))
        func reading(_ hour: Int, _ minute: Int, _ limits: [Limit]) -> Reading {
            Reading(account: AccountID("S"), at: Record.moment(26, hour, minute), limits: limits)
        }
        let week = Limit(kind: .week, used: Percent(40)!, resets: ResetTime(Record.moment(28, 13, 0)))
        let spent = reading(13, 0, [week, Limit(kind: session, used: Percent(100)!, resets: reset)])
        #expect(SpentLimitBack.between(spent, reading(13, 30, [week])).isEmpty)
        #expect(SpentLimitBack.between(spent, reading(14, 10, [week])) == [SpentLimitBack(account: AccountID("S"), limit: session, spentUntil: reset, how: .reset)])
        let nearly = reading(13, 0, [week, Limit(kind: session, used: Percent(99)!, resets: reset)])
        #expect(SpentLimitBack.between(nearly, reading(14, 10, [week, Limit(kind: session, used: Percent(0)!, resets: nil)])).isEmpty)
    }
}
