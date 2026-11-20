import Foundation
import Kit
import Testing

/// The chart page's twelve moments, each cut at a fixed minute of the record and named in
/// `fixtures/moments.json`. The sentences are written out as the page says them on the frozen
/// record in UTC. The page's moment "Now" is the last reading of the record.
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
         "No use yet this week. It resets Wed 21:00.",
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
        let sentences = try Record.picture(name).sentences(in: Record.calendar)
        #expect(sentences.forecast == forecast, "\(name)")
        #expect(sentences.record == record, "\(name)")
    }
}
