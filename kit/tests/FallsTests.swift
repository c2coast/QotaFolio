import Foundation
import Kit
import Testing

@Suite("Falls inside a week")
struct FallsTests {
    struct Seen: Equatable, CustomStringConvertible {
        let account: String, from: String, to: String, kind: Fall.Kind, hours: Double
        var description: String { "\(account) \(kind) \(from) to \(to), \(hours) h" }
    }

    /// The five banked resets of the record, as the owner lived them: three Fable resets that
    /// gave Fable back and half of it to the week, one full reset, and one Fable reset that
    /// happened somewhere inside a night with no polls.
    @Test("The five falls of the record, classified")
    func fiveFalls() {
        let seen = [Record.a, Record.b].flatMap { forecast in
            forecast.falls.map { fall in
                Seen(account: fall.before.account.rawValue, from: Record.minute(fall.before.at), to: Record.minute(fall.after.at),
                     kind: fall.kind, hours: (fall.hours * 10).rounded() / 10)
            }
        }
        #expect(seen == [
            Seen(account: "A", from: "Tue 18 Nov 13:56", to: "Tue 18 Nov 14:11", kind: .model, hours: 0.3),
            Seen(account: "A", from: "Tue 18 Nov 19:58", to: "Tue 18 Nov 20:13", kind: .full, hours: 0.3),
            Seen(account: "A", from: "Thu 20 Nov 03:55", to: "Thu 20 Nov 11:21", kind: .model, hours: 7.4),
            Seen(account: "B", from: "Sat 15 Nov 18:28", to: "Sat 15 Nov 18:58", kind: .model, hours: 0.5),
            Seen(account: "B", from: "Sun 16 Nov 04:24", to: "Sun 16 Nov 04:54", kind: .model, hours: 0.5),
        ])
    }

    /// A, Tue 18 Nov 13:56 to 14:11: Fable went from 93 to 2 and the week from 100 to 57. Fable
    /// may use at most half the week, so its 93 points were 46.5 of the week's. 100 - 46.5 = 53.5,
    /// and 57 is within five of it, so only Fable reset: the week gets 46.5 back, not 43 and not 100.
    /// Six hours later, the full reset gives the week all its 98 back, and Fable all its 51.
    @Test("One Fable point is half a weekly point")
    func fablePointIsHalfAWeekPoint() throws {
        let fall = try #require(Record.a.falls.first { Record.minute($0.before.at) == "Tue 18 Nov 13:56" })
        #expect(fall.before.limit(.week)?.used.value == 100)
        #expect(fall.before.limit(Record.fable)?.used.value == 93)
        #expect(fall.kind == .model)
        #expect(fall.givenBack[Record.fable] == 93)
        #expect(fall.givenBack[.week] == 46.5)

        let full = try #require(Record.a.falls.first { Record.minute($0.before.at) == "Tue 18 Nov 19:58" })
        #expect(full.kind == .full)
        #expect(full.givenBack[.week] == 98)
        #expect(full.givenBack[Record.fable] == 51)
    }
}
