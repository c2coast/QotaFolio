import Foundation
import Kit

/// `tools/forecast`: what the forecast said at every recorded poll, in each limit's verdict and in
/// the sentences a person reads, what then happened, and how often it was right. Reads a history
/// file of version 1.0.0. The shell script `tools/forecast` builds this and passes the frozen
/// record first; a path the person gives replaces it.
///
/// `--at` prints one moment: a name from `moments.json` beside the history file, or a day and a
/// time, "2025-11-18 23:45", in the Mac's time zone. `--account` keeps one account. `--draw` takes
/// a moment the same way and writes the graph at it to a PNG; `tools/forecast-draw.swift` has it.
@main
enum ForecastTool {
    static let usage = """
        usage: tools/forecast [--json] [--at <moment name | yyyy-MM-dd HH:mm>] [--account <id>] [usage-history.json]
               tools/forecast --draw <moment name | yyyy-MM-dd HH:mm> [--dark] [--increased-contrast] [--reduce-transparency]
                              [--12-hour] [--out <file.png>] [--account <id>] [usage-history.json]

        """

    static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var path = arguments.removeFirst()
        var json = false, at: String?, only: String?, draw: String?, out: String?, look = Look()
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            switch argument {
            case "--json": json = true
            case "--at" where !arguments.isEmpty: at = arguments.removeFirst()
            case "--draw" where !arguments.isEmpty: draw = arguments.removeFirst()
            case "--out" where !arguments.isEmpty: out = arguments.removeFirst()
            case "--dark": look.appearance.dark = true
            case "--increased-contrast": look.appearance.increasedContrast = true
            case "--reduce-transparency": look.appearance.reduceTransparency = true
            case "--12-hour": look.twelveHour = true
            case "--account" where !arguments.isEmpty: only = arguments.removeFirst()
            case _ where !argument.hasPrefix("--"): path = argument
            default: fail(usage)
            }
        }
        let history = URL(fileURLWithPath: path)
        let all = try LegacyHistory.readings(from: Data(contentsOf: history)).map(Forecast.init(readings:))
        let recordEnd = all.compactMap { $0.polls.last?.reading.at }.max() ?? .distantPast
        // The week first, then each model's week, as the polls carry them.
        let kinds = [Limit.Kind.week] + Set(all.flatMap { $0.polls.flatMap(\.verdicts.keys) })
            .filter { $0 != .week }.sorted { ($0.model ?? "") < ($1.model ?? "") }

        if let draw {
            guard let moment = moment(draw, beside: history) else { fail("no moment \(draw) beside \(path), and not a day and a time\n" + usage) }
            let account = only ?? moment.account
            try Self.draw(moment, named: draw, all.filter { account == nil || $0.polls.first?.reading.account.rawValue == account }, look: look, out: out)
            return
        }
        if let at {
            guard let moment = moment(at, beside: history) else { fail("no moment \(at) beside \(path), and not a day and a time\n" + usage) }
            let account = only ?? moment.account
            printMoment(moment.at, moment.label, all.filter { account == nil || $0.polls.first?.reading.account.rawValue == account }, kinds)
            return
        }
        let forecasts = all.filter { only == nil || $0.polls.first?.reading.account.rawValue == only }
        let scores = kinds.map { Score(of: forecasts, limit: $0, recordEnd: recordEnd) }
        let account = Score(accountsOf: forecasts, recordEnd: recordEnd)
        if json {
            printJSON(forecasts, kinds, scores, account, recordEnd)
        } else {
            printText(path, forecasts, kinds, scores, account, recordEnd)
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(message.utf8))
        exit(2)
    }

    static func label(_ kind: Limit.Kind) -> String { kind.model ?? "week" }

    /// The sentences' calendar: Gregorian, in the zone given.
    static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    // MARK: - A moment

    struct Moment: Decodable {
        let name, label, account: String
        let at: Double
    }

    /// A named moment from `moments.json` beside the history file, or a day and a time in the Mac's
    /// zone, which names no account.
    static func moment(_ text: String, beside history: URL) -> (at: Date, label: String?, account: String?)? {
        let file = history.deletingLastPathComponent().appending(path: "moments.json")
        if let data = try? Data(contentsOf: file), let moments = try? JSONDecoder().decode([Moment].self, from: data),
           let named = moments.first(where: { $0.name == text }) {
            return (Date(timeIntervalSince1970: named.at), named.label, named.account)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text).map { ($0, nil, nil) }
    }

    static func printMoment(_ at: Date, _ name: String?, _ forecasts: [Forecast], _ kinds: [Limit.Kind]) {
        let zone = TimeZone.current
        for forecast in forecasts {
            guard let poll = forecast.poll(at: at), let picture = forecast.picture(at: at) else {
                print("\(forecast.polls.first?.reading.account.rawValue ?? "?"): no poll at or before \(day(at, zone))")
                continue
            }
            print("\(name.map { "\($0). " } ?? "")Account \(picture.account.rawValue) at \(day(at, zone)), "
                + "the poll of \(day(poll.reading.at, zone)). Times are \(zone.identifier).")
            for kind in kinds {
                guard let verdict = poll.verdicts[kind], let used = poll.reading.limit(kind)?.used else { continue }
                print("  \(pad(label(kind), 5))  \(pad(percent(used.value), 6))  \(said(verdict, zone))")
            }
            let sentences = picture.sentences(in: TimeWords(calendar: calendar(zone)))
            print("  says   \(sentences.forecast)")
            if let record = sentences.record { print("  shows  \(record)") }
        }
    }

    // MARK: - For a person

    static func printText(_ path: String, _ forecasts: [Forecast], _ kinds: [Limit.Kind], _ scores: [Score], _ account: Score, _ end: Date) {
        let zone = TimeZone.current
        print("The forecast at every poll of \(path)")
        print("Times are \(zone.identifier). \"then\" is what happened next; right or wrong once it is known.")
        print("\"says\" is the forecast's sentence for the account; \"shows\" is the record's.")
        for forecast in forecasts {
            let outcomes = kinds.map { forecast.outcomes(of: $0, recordEnd: end) }
            for (i, poll) in forecast.polls.enumerated() {
                let head = [poll.reading.account.rawValue, day(poll.reading.at, zone)]
                for (k, kind) in kinds.enumerated() {
                    guard let verdict = poll.verdicts[kind], let used = poll.reading.limit(kind)?.used else { continue }
                    let then = outcomes[k][i]
                    print((head + [pad(label(kind), 5), pad(percent(used.value), 6), pad(said(verdict, zone), 54), happened(then, zone), judged(verdict, then)])
                        .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
                }
                guard let sentences = forecast.picture(at: poll.reading.at)?.sentences(in: TimeWords(calendar: calendar(zone))) else { continue }
                print((head + ["says ", sentences.forecast]).joined(separator: "  "))
                if let record = sentences.record { print((head + ["shows", record]).joined(separator: "  ")) }
            }
        }
        print("")
        print("Score over \(forecasts.map { "\($0.polls.count)" }.joined(separator: " + ")) polls; the record ends \(day(end, zone)).")
        for (kind, score) in zip(kinds, scores) {
            print("  \(pad(label(kind), 7))  \(score.right) right of \(score.judged) judged, \(score.flips) flips, "
                + "median timing error \(median(score)) over \(score.timingErrors.count) run-outs "
                + "(\(score.spoken) spoke, \(score.silent) silent)")
        }
        print("  account  \(account.right) right of \(account.judged) judged, \(account.named) of \(account.timingErrors.count) run-outs "
            + "named the limit that ran out first, \(account.flips) flips, median timing error \(median(account)) "
            + "(\(account.spoken) spoke, \(account.silent) silent)")
    }

    static func median(_ score: Score) -> String {
        score.medianError.map { String(format: "%.4f hours", $0) } ?? "none"
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
        let says: String?
        let shows: String?
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
        let spoken, silent, judged, right, named, flips, errors: Int
        let medianError: Double?
    }

    static func printJSON(_ forecasts: [Forecast], _ kinds: [Limit.Kind], _ scores: [Score], _ account: Score, _ end: Date) {
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
                let sentences = forecast.picture(at: poll.reading.at)?.sentences(in: TimeWords(calendar: calendar(.current)))
                emit(Line(account: poll.reading.account.rawValue, t: poll.reading.at.timeIntervalSince1970, limits: limits,
                          says: sentences?.forecast, shows: sentences?.record))
            }
        }
        for (name, score) in zip(kinds.map(label) + ["account"], scores + [account]) {
            emit(Scored(limit: name, spoken: score.spoken, silent: score.silent, judged: score.judged, right: score.right,
                        named: score.named, flips: score.flips, errors: score.timingErrors.count, medianError: score.medianError))
        }
    }
}
