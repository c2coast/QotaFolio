import Foundation
import Kit
import Testing

/// The week as the chart page shows it. `fixtures/chart-page.json` is the page's own code, run
/// under node on the frozen record in UTC: at every poll, its week view, its forecast for the
/// account, the sentence that says it with the clause a spent week adds, and the record's
/// sentence in points. Nothing in this repository writes it.
///
/// Where the Engine departs from the prototype, at the minutes after a reset (`PrototypeTests`),
/// `fixtures/chart-page-after-reset.json` is the page's own code run on the changed prototype, and
/// the sentences equal it there.
@Suite("Equal to the chart page at every poll")
struct ChartPageTests {
    static let expected: Expected = {
        let data = try! Data(contentsOf: Record.fixtures.appending(path: "chart-page.json"))
        return try! JSONDecoder().decode(Expected.self, from: data)
    }()

    static let afterReset: Departures = {
        let data = try! Data(contentsOf: Record.fixtures.appending(path: "chart-page-after-reset.json"))
        return try! JSONDecoder().decode(Departures.self, from: data)
    }()

    @Test("The week, the account's forecast and both sentences", arguments: [0, 1])
    func everyPoll(account: Int) throws {
        let want = Self.expected.accounts[account]
        let forecast = [Record.a, Record.b][account]
        #expect(forecast.polls.count == want.polls.count)
        var polls = want.polls
        for departure in Self.afterReset.accounts[account].polls { polls[departure.index] = departure.poll }
        for (poll, wanted) in zip(forecast.polls, polls) {
            let at = "\(want.account) \(Record.minute(poll.reading.at))"
            #expect(poll.reading.at.timeIntervalSince1970 == wanted.t, "\(at)")
            let picture = try #require(forecast.picture(at: poll.reading.at))
            let sentences = picture.sentences(in: TimeWords(timeZone: Record.zone, now: poll.reading.at))
            #expect(Self.withoutDates(sentences.forecast) == wanted.forecast, "\(at)")
            #expect(sentences.record.map(Self.withoutDates) == wanted.record, "\(at)")
            #expect(Week(picture) == wanted.week, "\(at)")
            let called = Called(picture.forecast)
            #expect([called.kind, called.first] == [wanted.kind, wanted.first], "\(at)")
            #expect([called.weekOut, called.fableOut] == [wanted.weekOut, wanted.fableOut], "\(at)")
            if let speed = called.speed { #expect(speed == wanted.speed, "\(at)") }
        }
    }

    /// A time said without its day is a riddle in the first hours of a week. Every clock time in
    /// every sentence of the record follows a day's name, and the date when the day's name alone
    /// would name another day.
    @Test("Every time in a sentence carries its day")
    func everyTimeHasItsDay() throws {
        var times = 0, said = 0
        for forecast in [Record.a, Record.b] {
            for poll in forecast.polls {
                let words = TimeWords(timeZone: Record.zone, now: poll.reading.at)
                let sentences = try #require(forecast.picture(at: poll.reading.at)).sentences(in: words)
                for sentence in [sentences.forecast, sentences.record].compactMap(\.self) {
                    times += sentence.ranges(of: /\d\d:\d\d/).count
                    said += sentence.ranges(of: Self.timeWord).count
                }
            }
        }
        #expect(times > 500)
        #expect(said == times)
    }

    /// The page says a day by its name alone. A day's name tells one day only within six days of
    /// the poll's, so a time seven days or more away says its date too, "Wed 26 Nov 21:00". On the
    /// record it happens four times: at A's first three polls after Wed 12 Nov 21:00 and its first
    /// after Wed 19 Nov 21:00, where the page says "No use yet this week. It resets Wed 21:00." of a
    /// reset a week away.
    @Test("A date is said only of a day seven days or more from the poll's")
    func datesAWeekAway() throws {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        var dated = 0
        for forecast in [Record.a, Record.b] {
            for poll in forecast.polls {
                let words = TimeWords(timeZone: Record.zone, now: poll.reading.at)
                let sentences = try #require(forecast.picture(at: poll.reading.at)).sentences(in: words)
                for sentence in [sentences.forecast, sentences.record].compactMap(\.self) {
                    for match in sentence.matches(of: Self.timeWord) {
                        guard let date = match.output.2?.split(separator: " ") else { continue }
                        dated += 1
                        let month = try #require(months.firstIndex(of: String(date[1]))) + 1
                        let day = try #require(Record.calendar.date(from: DateComponents(year: 2025, month: month, day: Int(date[0])!)))
                        let days = Record.calendar.dateComponents([.day], from: Record.calendar.startOfDay(for: poll.reading.at), to: day).day!
                        #expect(abs(days) >= 7, "\(Record.minute(poll.reading.at)): \(match.output.0)")
                    }
                }
            }
        }
        #expect(dated == 4)
    }

    /// "Wed 21:00" or "Wed 26 Nov 21:00": a day's name, a date when it is said, and the clock.
    static var timeWord: Regex<(Substring, Substring, Substring?, Substring, Substring)> {
        /(Mon|Tue|Wed|Thu|Fri|Sat|Sun)( \d{1,2} (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec))? (\d\d):(\d\d)/
    }

    /// The sentence with each date taken out, as the page says it.
    static func withoutDates(_ sentence: String) -> String {
        sentence.replacing(timeWord) { "\($0.output.1) \($0.output.3):\($0.output.4)" }
    }

    /// The account's forecast, scored as the page's sentence says it, against the first limit that
    /// ran out. The page's own sentences scored this on the record, by the same rule for the minutes
    /// after a reset; none of the four may get worse.
    @Test("The score of what is said is no worse than the page's")
    func score() throws {
        let score = Score(accountsOf: [Record.a, Record.b], recordEnd: Record.end)
        let page = Self.afterReset.score
        #expect(Double(score.right) / Double(score.judged) >= Double(page.right) / Double(page.judged),
                "\(score.right) right of \(score.judged)")
        #expect(Double(score.named) / Double(score.timingErrors.count) >= Double(page.named) / Double(page.timedRunOuts),
                "\(score.named) named of \(score.timingErrors.count)")
        #expect(score.flips <= page.flips)
        #expect(try #require(score.medianError) <= page.medianError)
    }

    /// The account's forecast as the page's `forecast(v)` writes it.
    struct Called {
        var kind = "live", first: String?, speed: String?, weekOut: Double?, fableOut: Double?

        init(_ forecast: AccountForecast) {
            switch forecast {
            case .spent: kind = "spent"
            case .notStarted, .silent: break
            case .modelSpent(let week):
                weekOut = Self.out(week)
                first = weekOut.map { _ in "week" }
                if case .runsOut(_, _, let speed) = week { self.speed = Self.word(speed) }
                if case .lasts(_, _, let speed) = week { self.speed = Self.word(speed) }
            case .runsOut(let limit, let at, let speed, let other):
                first = limit.model ?? "week"
                (weekOut, fableOut) = limit == .week ? (at.timeIntervalSince1970, other.flatMap(Self.out)) : (other.flatMap(Self.out), at.timeIntervalSince1970)
                self.speed = Self.word(speed)
            case .lasts(_, _, let speed):
                self.speed = Self.word(speed)
            }
        }

        static func out(_ verdict: Verdict) -> Double? {
            if case .runsOut(let at, _, _) = verdict { at.timeIntervalSince1970 } else { nil }
        }

        static func word(_ speed: Verdict.Speed) -> String { speed == .burn ? "burn" : "week" }
    }

    /// The page's week view, in the times it holds: its bounds, how many points it draws and
    /// whether the first is the week opening at zero, the lead-in nobody recorded, where each fall
    /// ends, each gap with the fall tied to it, each stretch at the limit, and the work done now.
    struct Week: Decodable, Equatable {
        let start, reset: Double
        let points: Int
        let zero: Bool
        let unrecorded: [Double]?
        let falls: [Double]
        let gaps: [[Double?]]
        let atLimit: [[Double]]
        let work: [Double?]

        init(_ picture: WeekPicture) {
            func s(_ date: Date) -> Double { date.timeIntervalSince1970 }
            start = s(picture.start)
            reset = s(picture.resets.instant)
            points = picture.points.count
            zero = !picture.points[0].polled
            unrecorded = picture.unrecorded.map { [s($0.start), s($0.end)] }
            falls = picture.falls.map { s($0.after.at) }
            gaps = picture.gaps.map { [s($0.before.at), s($0.after.at), $0.fall.map { s($0.after.at) }] }
            atLimit = picture.atLimit.map { [s($0.start), s($0.end)] }
            work = [picture.now.week.work, picture.now.model?.work]
        }
    }

    struct Expected: Decodable {
        let score: Score
        let accounts: [Account]

        struct Score: Decodable {
            let spoken, silent, judged, right, named, timedRunOuts, flips: Int
            let medianError: Double
        }

        struct Account: Decodable {
            let account: String
            let polls: [Poll]
        }

        struct Poll: Decodable {
            let t: Double
            let forecast: String
            let record: String?
            let kind: String
            let first, speed: String?
            let weekOut, fableOut: Double?
            let week: Week
        }
    }

    /// The page's answer on the changed prototype at each poll where it differs, by the poll's place.
    struct Departures: Decodable {
        let score: Expected.Score
        let accounts: [Account]

        struct Account: Decodable {
            let polls: [Departure]
        }

        struct Departure: Decodable {
            let index: Int
            let poll: Expected.Poll

            init(from decoder: Decoder) throws {
                index = try decoder.container(keyedBy: Key.self).decode(Int.self, forKey: .index)
                poll = try Expected.Poll(from: decoder)
            }

            enum Key: CodingKey { case index }
        }
    }
}
