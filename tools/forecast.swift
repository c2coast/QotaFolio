import Foundation
import Kit

/// `tools/forecast`: what the forecast said at every recorded poll, what then happened, and how
/// often it was right. Reads a history file of version 1.0.0; the shell script `tools/forecast`
/// builds this and passes the frozen record when no path is given.
@main
enum ForecastTool {
    static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let json = arguments.contains("--json")
        arguments.removeAll { $0 == "--json" }
        guard arguments.count == 1 else {
            FileHandle.standardError.write(Data("usage: tools/forecast [--json] [usage-history.json]\n".utf8))
            exit(2)
        }
        let accounts = try LegacyHistory.readings(from: Data(contentsOf: URL(fileURLWithPath: arguments[0])))
        let forecasts = accounts.map(Forecast.init(readings:))
        let recordEnd = forecasts.compactMap { $0.polls.last?.reading.at }.max() ?? .distantPast
        // The week first, then each model's week, as the polls carry them.
        let kinds = [Limit.Kind.week] + Set(forecasts.flatMap { $0.polls.flatMap(\.verdicts.keys) })
            .filter { $0 != .week }.sorted { ($0.model ?? "") < ($1.model ?? "") }
        let scores = kinds.map { Score(of: forecasts, limit: $0, recordEnd: recordEnd) }
        if json {
            printJSON(forecasts, kinds, scores, recordEnd)
        } else {
            printText(arguments[0], forecasts, kinds, scores, recordEnd)
        }
    }

    static func label(_ kind: Limit.Kind) -> String { kind.model ?? "week" }

    // MARK: - For a person

    static func printText(_ path: String, _ forecasts: [Forecast], _ kinds: [Limit.Kind], _ scores: [Score], _ end: Date) {
        let zone = TimeZone.current
        print("The forecast at every poll of \(path)")
        print("Times are \(zone.identifier). \"then\" is what happened next; right or wrong once it is known.")
        for forecast in forecasts {
            let outcomes = kinds.map { forecast.outcomes(of: $0, recordEnd: end) }
            for (i, poll) in forecast.polls.enumerated() {
                for (k, kind) in kinds.enumerated() {
                    guard let verdict = poll.verdicts[kind], let used = poll.reading.limit(kind)?.used else { continue }
                    let head = [poll.reading.account.rawValue, day(poll.reading.at, zone), pad(label(kind), 5), pad(percent(used.value), 6)]
                    let then = outcomes[k][i]
                    print((head + [pad(said(verdict, zone), 54), happened(then, zone), judged(verdict, then)])
                        .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
                }
            }
        }
        print("")
        print("Score over \(forecasts.map { "\($0.polls.count)" }.joined(separator: " + ")) polls; the record ends \(day(end, zone)).")
        for (kind, score) in zip(kinds, scores) {
            let median = score.medianError.map { String(format: "%.4f hours", $0) } ?? "none"
            print("  \(pad(label(kind), 5))  \(score.right) right of \(score.judged) judged, \(score.flips) flips, "
                + "median timing error \(median) over \(score.timingErrors.count) run-outs "
                + "(\(score.spoken) spoke, \(score.silent) silent)")
        }
    }

    static func said(_ verdict: Verdict, _ zone: TimeZone) -> String {
        switch verdict {
        case .spent: "spent"
        case .silent(.notStarted): "silent: not started"
        case .silent(.noClockYet): "silent: no clock yet"
        case .silent(.insideOneStep): "silent: inside one step"
        case .runsOut(let at, let rate, let speed): "runs out \(day(at, zone)) \(pace(rate, speed))"
        case .lasts(let landing, let rate, let speed): "lasts, \(percent(landing)) at reset \(pace(rate, speed))"
        }
    }

    static func happened(_ outcome: Outcome, _ zone: TimeZone) -> String {
        switch outcome {
        case .spent: ""
        case .unknown: pad("then not known yet", 38)
        case .ranOut(let at, let gap): pad("then ran out \(day(at, zone))" + (gap > 1 ? String(format: " in a %.1f h gap", gap) : ""), 38)
        case .lasted(let landing): pad("then lasted, \(percent(landing)) at reset", 38)
        }
    }

    static func judged(_ verdict: Verdict, _ outcome: Outcome) -> String {
        switch (verdict, outcome) {
        case (.runsOut, .ranOut), (.lasts, .lasted): "right"
        case (.runsOut, .lasted), (.lasts, .ranOut): "wrong"
        default: ""
        }
    }

    static func pace(_ rate: Double, _ speed: Verdict.Speed) -> String {
        String(format: "(%.2f an hour, ", rate) + (speed == .burn ? "last 3 h)" : "week's pace)")
    }

    static func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }

    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    /// "Fri 14 Nov 03:57", in the zone given.
    static func day(_ date: Date, _ zone: TimeZone) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(weekday: .abbreviated) \(day: .twoDigits) \(month: .abbreviated) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: Locale(identifier: "en_GB"), timeZone: zone, calendar: Calendar(identifier: .gregorian)))
    }

    // MARK: - For a program

    struct Line: Encodable {
        let account: String
        let t: Double
        let limits: [String: Said]
    }

    struct Said: Encodable {
        let kind: String
        var why: String?
        var at: Double?
        var rate: Double?
        var landing: Double?
        var speed: String?
        let givenBack: Double
    }

    struct Scored: Encodable {
        let limit: String
        let spoken, silent, judged, right, flips, errors: Int
        let medianError: Double?
    }

    static func printJSON(_ forecasts: [Forecast], _ kinds: [Limit.Kind], _ scores: [Score], _ end: Date) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func emit(_ value: some Encodable) { print(String(decoding: try! encoder.encode(value), as: UTF8.self)) }
        for forecast in forecasts {
            for poll in forecast.polls {
                var limits: [String: Said] = [:]
                for kind in kinds {
                    guard let verdict = poll.verdicts[kind] else { continue }
                    var said = Said(kind: "", givenBack: poll.givenBack[kind] ?? 0)
                    switch verdict {
                    case .spent: said = Said(kind: "spent", givenBack: said.givenBack)
                    case .silent(let why):
                        said = Said(kind: "silent", givenBack: said.givenBack)
                        said.why = switch why {
                        case .notStarted: "not started"
                        case .noClockYet: "no clock yet"
                        case .insideOneStep: "inside one step"
                        }
                    case .runsOut(let at, let rate, let speed):
                        said = Said(kind: "runsOut", givenBack: said.givenBack)
                        (said.at, said.rate, said.speed) = (at.timeIntervalSince1970, rate, speed == .burn ? "burn" : "week")
                    case .lasts(let landing, let rate, let speed):
                        said = Said(kind: "lasts", givenBack: said.givenBack)
                        (said.landing, said.rate, said.speed) = (landing, rate, speed == .burn ? "burn" : "week")
                    }
                    limits[label(kind)] = said
                }
                emit(Line(account: poll.reading.account.rawValue, t: poll.reading.at.timeIntervalSince1970, limits: limits))
            }
        }
        for (kind, score) in zip(kinds, scores) {
            emit(Scored(limit: label(kind), spoken: score.spoken, silent: score.silent, judged: score.judged,
                        right: score.right, flips: score.flips, errors: score.timingErrors.count, medianError: score.medianError))
        }
    }
}
