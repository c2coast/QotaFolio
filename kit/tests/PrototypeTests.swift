import Foundation
import Kit
import Testing

/// The Engine is the method the prototype scored on the owner's record. `fixtures/prototype.json`
/// is the prototype's own answer on that record, frozen, and never written from this code. At
/// every poll, each limit's verdict is equal to it: the kind, the reason for silence and the speed
/// are the same, and every time, rate and landing is the same number to the last bit.
@Suite("Equal to the prototype at every poll")
struct PrototypeTests {
    static let expected: Expected = {
        let data = try! Data(contentsOf: Record.fixtures.appending(path: "prototype.json"))
        return try! JSONDecoder().decode(Expected.self, from: data)
    }()

    @Test("Every verdict, every point given back and every outcome", arguments: [0, 1])
    func everyPoll(account: Int) {
        let want = Self.expected.accounts[account]
        let forecast = [Record.a, Record.b][account]
        #expect(forecast.polls.count == want.polls.count)
        let weekOutcomes = forecast.outcomes(of: .week, recordEnd: Record.end)
        let fableOutcomes = forecast.outcomes(of: Record.fable, recordEnd: Record.end)
        for (i, (poll, wanted)) in zip(forecast.polls, want.polls).enumerated() {
            let at = "\(want.account) poll \(i), \(Record.minute(poll.reading.at))"
            #expect(poll.reading.at.timeIntervalSince1970 == wanted.t, "\(at)")
            #expect(Said(poll.verdicts[.week]) == wanted.weekVerdict, "\(at) week")
            #expect(Said(poll.verdicts[Record.fable]) == wanted.fableVerdict, "\(at) Fable")
            #expect(poll.givenBack[.week] == wanted.weekGivenBack, "\(at) week given back")
            #expect(poll.givenBack[Record.fable] == wanted.fableGivenBack, "\(at) Fable given back")
            #expect(Then(weekOutcomes[i]) == wanted.weekTruth, "\(at) week outcome")
            #expect(Then(fableOutcomes[i]) == wanted.fableTruth, "\(at) Fable outcome")
        }
    }

    @Test("Every fall", arguments: [0, 1])
    func everyFall(account: Int) {
        let readings = Record.accounts[account]
        let falls = [Record.a, Record.b][account].falls.map { fall in
            Expected.Fall(
                before: readings.firstIndex(of: fall.before)!, after: readings.firstIndex(of: fall.after)!,
                kind: Self.word(fall.kind),
                week: [fall.before.limit(.week)!.used.value, fall.after.limit(.week)!.used.value],
                fable: [fall.before.limit(Record.fable)!.used.value, fall.after.limit(Record.fable)!.used.value],
                givenBack: ["week": fall.givenBack[.week]!, "fable": fall.givenBack[Record.fable]!], hours: fall.hours)
        }
        #expect(falls == Self.expected.accounts[account].falls)
    }

    static func word(_ kind: Fall.Kind) -> String {
        switch kind {
        case .model: "Fable"
        case .full: "full"
        case .unexplained: "unexplained"
        }
    }

    /// The prototype's own score for each limit, over both accounts: verdicts right out of judged,
    /// flips, and the median timing error of run-outs said and seen.
    @Test("The score of each limit")
    func scores() {
        for (name, kind) in [("week", Limit.Kind.week), ("fable", Record.fable)] {
            let score = Score(of: [Record.a, Record.b], limit: kind, recordEnd: Record.end)
            let want = Self.expected.scores[name]!
            let got: [Int] = [score.spoken, score.silent, score.judged, score.right, score.flips, score.timingErrors.count]
            let wanted: [Int] = [want.spoken, want.silent, want.judged, want.right, want.flips, want.errors]
            #expect(Record.end.timeIntervalSince1970 == Self.expected.lastPoll)
            #expect(got == wanted, "\(name): spoken, silent, judged, right, flips, timed run-outs")
            #expect(score.medianError == want.medianError, "\(name)")
        }
    }

    /// A verdict as the prototype writes one.
    struct Said: Decodable, Equatable {
        var kind: String, why: String?, speed: String?, at: Double?, rate: Double?, landing: Double?

        init(_ verdict: Verdict?) {
            switch verdict {
            case nil: kind = "none"
            case .spent: kind = "spent"
            case .silent(let silence):
                kind = "silent"
                why = switch silence {
                case .notStarted: "not started"
                case .noClockYet: "no clock yet"
                case .insideOneStep: "inside one step"
                }
            case .runsOut(let date, let rate, let speed):
                (kind, at, self.rate, self.speed) = ("runsOut", date.timeIntervalSince1970, rate, Self.word(speed))
            case .lasts(let landing, let rate, let speed):
                (kind, self.landing, self.rate, self.speed) = ("lasts", landing, rate, Self.word(speed))
            }
        }

        static func word(_ speed: Verdict.Speed) -> String { speed == .burn ? "burn" : "week" }
    }

    /// An outcome as the prototype writes one.
    struct Then: Decodable, Equatable {
        var kind: String, at: Double?, slack: Double?, landing: Double?

        init(_ outcome: Outcome) {
            switch outcome {
            case .spent: kind = "spent"
            case .unknown: kind = "censored"
            case .ranOut(let date, let gap): (kind, at, slack) = ("runsOut", date.timeIntervalSince1970, gap)
            case .lasted(let landing): (kind, self.landing) = ("lasts", landing)
            }
        }
    }

    struct Expected: Decodable {
        let lastPoll: Double
        let scores: [String: Score]
        let accounts: [Account]

        struct Score: Decodable {
            let spoken, silent, judged, right, flips, errors: Int
            let medianError: Double
        }

        struct Account: Decodable {
            let account: String
            let falls: [Fall]
            let polls: [Poll]
        }

        struct Fall: Decodable, Equatable {
            let before, after: Int
            let kind: String
            let week, fable: [Double]
            let givenBack: [String: Double]
            let hours: Double
        }

        struct Poll: Decodable {
            let t: Double
            let weekVerdict, fableVerdict: Said
            let weekGivenBack, fableGivenBack: Double
            let weekTruth, fableTruth: Then
        }
    }
}
