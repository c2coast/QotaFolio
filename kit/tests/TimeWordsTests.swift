import Foundation
import Kit
import Testing

/// How a time is said, read on Wed 26 Nov 2025 at 21:02 UTC, two minutes after a week reset.
@Suite("The time words")
struct TimeWordsTests {
    static let now = Record.moment(26, 21, 2)
    static let words = TimeWords(timeZone: Record.zone, now: now)

    /// Within six days of today, a day's name tells the day. A week on, "Wed 21:00" would read as
    /// two minutes ago, so the next reset says its date.
    @Test("A day's name within six days of today, and the date from seven days on")
    func days() {
        #expect(Self.words.day(Record.moment(26, 21, 0)) == "Wed 21:00")
        #expect(Self.words.day(Record.moment(27, 3, 15)) == "Thu 03:15")
        #expect(Self.words.day(Record.moment(32, 23, 59)) == "Tue 23:59")
        #expect(Self.words.day(Record.moment(33, 0, 0)) == "Wed 3 Dec 00:00")
        #expect(Self.words.day(Record.moment(33, 21, 0)) == "Wed 3 Dec 21:00")
        #expect(Self.words.day(Record.moment(20, 9, 30)) == "Thu 09:30")
        #expect(Self.words.day(Record.moment(19, 23, 59)) == "Wed 19 Nov 23:59")
        #expect(Self.words.quarterDay(Record.moment(33, 20, 53)) == "Wed 3 Dec 21:00")
    }

    @Test("On a 12-hour clock the date stands before the hour")
    func twelveHour() {
        let words = TimeWords(timeZone: Record.zone, twelveHour: true, now: Self.now)
        #expect(words.day(Record.moment(33, 21, 0)) == "Wed 3 Dec 9:00 PM")
        #expect(words.day(Record.moment(27, 0, 5)) == "Thu 12:05 AM")
    }

    /// Today is the calendar's day: in New York, 21:02 UTC is 16:02 on the same Wednesday, and Wed
    /// 3 Dec 02:00 UTC is Tue 2 Dec 21:00 there, six days on.
    @Test("Today is the day in the calendar's zone")
    func zone() {
        let words = TimeWords(timeZone: TimeZone(identifier: "America/New_York")!, now: Self.now)
        #expect(words.day(Record.moment(33, 2, 0)) == "Tue 21:00")
        #expect(words.day(Record.moment(33, 5, 0)) == "Wed 3 Dec 00:00")
    }
}
