import Foundation
import Kit
import Testing

/// The chart page's twelve moments, each cut at a fixed minute of the record and named in
/// `fixtures/moments.json`. The sentences are written out as the page says them on the frozen
/// record in UTC. The page's moment "Now" is the last reading of the record.
///
/// One departs from the page by the date rule of `TimeWords`. At new-week-at-zero, Wed 19 Nov 21:02,
/// the week resets Wed 26 Nov 21:00: seven days away, so the reset says its date, where the page's
/// "It resets Wed 21:00" read as two minutes ago.
@Suite("The page's twelve moments, in words")
struct PageMomentsTests {
    static let said: [(name: String, forecast: String, record: String?)] = [
        ("after-banked-reset",
         "At the last three hours’ pace, the week reaches its limit around Wed 19:15, 1h 45m before it resets.",
         "A full banked reset at Tue 20:13 gave back 98 points."),
        ("after-a-gap",
         "At the last three hours’ pace, the week reaches its limit around Wed 20:00, 1h 0m before it resets.",
         "Not watched from Wed 01:46 to Wed 09:17; the week rose 32 points in that time."),
        ("spent-week",
         "Spent. Back Fri 13:00. Fable reads 20% and waits on the week.",
         "At the limit since Tue 13:56."),
        ("new-week",
         "At the last three hours’ pace, Fable reaches its limit around Thu 13:45, and the week around Thu 18:00.",
         nil),
        ("fable-near-its-limit",
         "At the last three hours’ pace, Fable reaches its limit around Fri 21:30, and the week around Fri 23:30.",
         nil),
        ("last-reading",
         "Spent. Back Wed 21:00. Fable reads 99% and waits on the week.",
         "At the limit since Thu 19:27."),
        ("longest-gap",
         "At this week’s pace, the week reaches its limit around Mon 20:30, 3d 16h before it resets.",
         "Not watched from Sun 05:24 to Sun 20:44; the week rose 9 points in that time."),
        ("out-in-15-minutes",
         "At the last three hours’ pace, the week reaches its limit around Fri 00:45, 5d 20h before it resets.",
         nil),
        ("fable-spent-week-not",
         "Fable is spent until Fri 13:00. At the last three hours’ pace, other models reach the week’s limit around Sat 03:00.",
         nil),
        ("before-the-reset",
         "At the last three hours’ pace, the week lasts to its reset Wed 21:00 with about 20% left, and Fable with about 53%.",
         "Not watched from Wed 01:46 to Wed 09:17; the week rose 32 points in that time."),
        ("record-starts-mid-week",
         "At the last three hours’ pace, Fable reaches its limit around Wed 23:00, and the week around Wed 23:45.",
         "Nothing was recorded before Wed 14:16, when the week already read 1%."),
        ("new-week-at-zero",
         "No use yet this week. It resets Wed 26 Nov 21:00.",
         nil),
    ]

    @Test("Every named moment has its sentences here")
    func allTwelve() {
        #expect(Set(Self.said.map(\.name)) == Set(Record.moments.keys))
        #expect(Self.said.count == 12)
    }

    @Test("The sentences at each moment", arguments: Self.said.indices)
    func sentences(_ k: Int) throws {
        let (name, forecast, record) = Self.said[k]
        let picture = try Record.picture(name)
        let sentences = picture.sentences(in: TimeWords(calendar: Record.calendar, now: picture.now.at))
        #expect(sentences.forecast == forecast, "\(name)")
        #expect(sentences.record == record, "\(name)")
    }

    /// On a 12-hour clock the sentences keep the page's words and say each time as the Mac's clock
    /// does: the hour from 1 to 12, and AM or PM. Worked by hand from the 24-hour sentences above:
    /// an evening, a time in the hour after midnight, and a reset on the hour.
    @Test("On a 12-hour clock, the sentences say each time with AM or PM")
    func twelveHour() throws {
        let said = try ["after-banked-reset", "out-in-15-minutes", "new-week-at-zero"].map { name in
            let picture = try Record.picture(name)
            return picture.sentences(in: TimeWords(calendar: Record.calendar, twelveHour: true, now: picture.now.at))
        }
        #expect(said[0].forecast == "At the last three hours’ pace, the week reaches its limit around Wed 7:15 PM, 1h 45m before it resets.")
        #expect(said[0].record == "A full banked reset at Tue 8:13 PM gave back 98 points.")
        #expect(said[1].forecast == "At the last three hours’ pace, the week reaches its limit around Fri 12:45 AM, 5d 20h before it resets.")
        #expect(said[2].forecast == "No use yet this week. It resets Wed 26 Nov 9:00 PM.")
    }
}
