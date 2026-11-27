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

    /// A made-up week that resets Wed 3 Dec 21:00. At Tue 2 Dec 14:00 the week reads 40 and Fable
    /// 20; at 14:15 the week reads 37 and Fable still 20. The week fell 3 points. Fable did not fall,
    /// and a full reset would leave the week near zero, or more than five under 40 - 20 / 2 = 30,
    /// so neither explains it: the fall is unexplained, and the week gets its 3 points back.
    /// The record has no such fall, and its sentence does not name a reset it cannot see.
    @Test("A fall the method cannot classify is said as the week giving points back, with no reason")
    func unexplained() throws {
        let reset = ResetTime(Self.december(3, 21, 0))
        func reading(_ hour: Int, _ minute: Int, week: Double, fable: Double) -> Reading {
            Reading(account: AccountID("M"), at: Self.december(2, hour, minute), limits: [
                Limit(kind: .week, used: Percent(week)!, resets: reset), Limit(kind: Record.fable, used: Percent(fable)!, resets: reset),
            ])
        }
        let forecast = Forecast(readings: [reading(14, 0, week: 40, fable: 20), reading(14, 15, week: 37, fable: 20)])
        let fall = try #require(forecast.falls.first)
        #expect(fall.kind == .unexplained)
        #expect(fall.givenBack[.week] == 3)
        let picture = try #require(forecast.picture(at: Self.december(2, 14, 15)))
        let words = TimeWords(timeZone: Record.zone, now: Self.december(2, 14, 15))
        #expect(picture.sentences(in: words).record == "At Tue 14:15 the week gave back 3 points; the readings do not say why.")
    }

    static func december(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Record.calendar.date(from: DateComponents(year: 2025, month: 12, day: day, hour: hour, minute: minute))!
    }
}
