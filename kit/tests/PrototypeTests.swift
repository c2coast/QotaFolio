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

    @Test("Every verdict and every point given back", arguments: [0, 1])
    func everyPoll(account: Int) {
        let want = Self.expected.accounts[account]
        let forecast = [Record.a, Record.b][account]
        #expect(forecast.polls.count == want.polls.count)
        for (i, (poll, wanted)) in zip(forecast.polls, want.polls).enumerated() {
            let at = "\(want.account) poll \(i), \(Record.minute(poll.reading.at))"
            #expect(poll.reading.at.timeIntervalSince1970 == wanted.t, "\(at)")
            #expect(Said(poll.verdicts[.week]) == wanted.weekVerdict, "\(at) week")
            #expect(Said(poll.verdicts[Record.fable]) == wanted.fableVerdict, "\(at) Fable")
            #expect(poll.givenBack[.week] == wanted.weekGivenBack, "\(at) week given back")
            #expect(poll.givenBack[Record.fable] == wanted.fableGivenBack, "\(at) Fable given back")
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

    struct Expected: Decodable {
        let accounts: [Account]

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
        }
    }
}
