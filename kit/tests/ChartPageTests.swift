import Foundation
import Kit
import Testing

/// The week as the chart page shows it. `fixtures/chart-page.json` is the page's own code, run
/// under node on the frozen record in UTC: at every poll, its week view, its forecast for the
/// account, the sentence that says it with the clause a spent week adds, and the record's
/// sentence in points. Nothing in this repository writes it.
@Suite("Equal to the chart page at every poll")
struct ChartPageTests {
    static let expected: Expected = {
        let data = try! Data(contentsOf: Record.fixtures.appending(path: "chart-page.json"))
        return try! JSONDecoder().decode(Expected.self, from: data)
    }()

    @Test("The week, the account's forecast and both sentences", arguments: [0, 1])
    func everyPoll(account: Int) throws {
        let want = Self.expected.accounts[account]
        let forecast = [Record.a, Record.b][account]
        #expect(forecast.polls.count == want.polls.count)
        for (poll, wanted) in zip(forecast.polls, want.polls) {
            let at = "\(want.account) \(Record.minute(poll.reading.at))"
            #expect(poll.reading.at.timeIntervalSince1970 == wanted.t, "\(at)")
            let picture = try #require(forecast.picture(at: poll.reading.at))
            let sentences = picture.sentences(in: Record.calendar)
            #expect(sentences.forecast == wanted.forecast, "\(at)")
            #expect(sentences.record == wanted.record, "\(at)")
            #expect(Week(picture) == wanted.week, "\(at)")
            let called = Called(picture.forecast)
            #expect([called.kind, called.first] == [wanted.kind, wanted.first], "\(at)")
            #expect([called.weekOut, called.fableOut] == [wanted.weekOut, wanted.fableOut], "\(at)")
            if let speed = called.speed { #expect(speed == wanted.speed, "\(at)") }
        }
    }

    /// A time said without its day is a riddle in the first hours of a week. Every clock time in
    /// every sentence of the record follows a day's name.
    @Test("Every time in a sentence carries its day")
    func everyTimeHasItsDay() throws {
        let days = Set(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        var times = 0
        for forecast in [Record.a, Record.b] {
            for poll in forecast.polls {
                let sentences = try #require(forecast.picture(at: poll.reading.at)).sentences(in: Record.calendar)
                for sentence in [sentences.forecast, sentences.record].compactMap(\.self) {
                    for range in sentence.ranges(of: /\d\d:\d\d/) {
                        times += 1
                        let before = sentence[..<range.lowerBound]
                        #expect(before.hasSuffix(" ") && days.contains(String(before.dropLast().suffix(3))), "\(sentence)")
                    }
                }
            }
        }
        #expect(times > 500)
    }

    /// The account's forecast, scored as the page's sentence says it, against the first limit that
    /// ran out. The page's own sentences scored this on the record; none of the four may get worse.
    @Test("The score of what is said is no worse than the page's")
    func score() throws {
        let score = Score(accountsOf: [Record.a, Record.b], recordEnd: Record.end)
        let page = Self.expected.score
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
}
