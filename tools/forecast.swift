import Foundation
import Kit

/// `tools/forecast`: what the forecast said at every recorded poll, in each limit's verdict and in
/// the sentences a person reads, what then happened, and how often it was right. Reads a history
/// file of version 1.0.0, or a folder of its files, where the snapshots give the newest poll. The
/// shell script `tools/forecast` builds this and passes the frozen record first; a path the person
/// gives replaces it.
///
/// `--at` prints one moment as the app says it, each account's `AccountNow`: a name from
/// `moments.json` beside the history, a day and a time, "2025-11-18 23:45", in the Mac's time zone,
/// or `now`. `--since` prints and scores only the polls from a moment on, so a newer copy is scored
/// on the days an older one does not hold. `--account` keeps one account. `--draw` takes a moment
/// the same way and writes the graph at it to a PNG; `tools/forecast-draw.swift` has it.
@main
enum ForecastTool {
    static let usage = """
        usage: tools/forecast [--json] [--at <moment name | yyyy-MM-dd HH:mm | now>] [--since <moment name | yyyy-MM-dd HH:mm>]
                              [--account <id>] [usage-history.json | folder]
               tools/forecast --draw <moment name | yyyy-MM-dd HH:mm | now> [--dark] [--increased-contrast] [--reduce-transparency]
                              [--12-hour] [--width <points>] [--out <file.png>] [--account <id>] [usage-history.json | folder]

        """

    static func main() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var path = arguments.removeFirst()
        var json = false, at: String?, since: String?, only: String?, draw: String?, out: String?, look = Look()
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            switch argument {
            case "--json": json = true
            case "--at" where !arguments.isEmpty: at = arguments.removeFirst()
            case "--since" where !arguments.isEmpty: since = arguments.removeFirst()
            case "--draw" where !arguments.isEmpty: draw = arguments.removeFirst()
            case "--out" where !arguments.isEmpty: out = arguments.removeFirst()
            case "--dark": look.appearance.dark = true
            case "--increased-contrast": look.appearance.increasedContrast = true
            case "--reduce-transparency": look.appearance.reduceTransparency = true
            case "--12-hour": look.twelveHour = true
            case "--width" where !arguments.isEmpty:
                guard let width = Double(arguments.removeFirst()), width >= 120 else { fail("--width takes the chart's width in points, 120 or more\n" + usage) }
                look.width = width
            case "--account" where !arguments.isEmpty: only = arguments.removeFirst()
            case _ where !argument.hasPrefix("--"): path = argument
            default: fail(usage)
            }
        }
        let (history, readings) = try read(path)
        func kept(_ account: String?) -> [[Reading]] { readings.filter { account == nil || $0[0].account.rawValue == account } }

        if let draw {
            guard let moment = moment(draw, beside: history) else { fail("no moment \(draw) beside \(path), and not a day and a time\n" + usage) }
            try Self.draw(moment, named: draw, kept(only ?? moment.account), look: look, out: out)
            return
        }
        if let at {
            guard let moment = moment(at, beside: history) else { fail("no moment \(at) beside \(path), and not a day and a time\n" + usage) }
            printMoment(moment.at, moment.label, kept(only ?? moment.account))
            return
        }
        let all = readings.map(Forecast.init(readings:))
        let recordEnd = all.compactMap { $0.polls.last?.reading.at }.max() ?? .distantPast
        // The week first, then each model's week, as the polls carry them.
        let kinds = [Limit.Kind.week] + Set(all.flatMap { $0.polls.flatMap(\.verdicts.keys) })
            .filter { $0 != .week }.sorted { ($0.model ?? "") < ($1.model ?? "") }
        var from = Date.distantPast
        if let since {
            guard let moment = moment(since, beside: history) else { fail("--since takes a day and a time, \"2025-11-18 23:45\", or a moment's name\n" + usage) }
            from = moment.at
        }
        let forecasts = all.filter { only == nil || $0.polls.first?.reading.account.rawValue == only }
        // The verdicts were read on the whole history, and an outcome reads only the polls after its
        // own, so dropping the polls before `from` changes neither.
        let scored = forecasts.map { Forecast(polls: $0.polls.filter { $0.reading.at >= from }, falls: $0.falls) }
        let scores = kinds.map { Score(of: scored, limit: $0, recordEnd: recordEnd) }
        let account = Score(accountsOf: scored, recordEnd: recordEnd)
        if json {
            printJSON(forecasts, from, kinds, scores, account, recordEnd)
        } else {
            printText(path, forecasts, from, kinds, scores, account, recordEnd)
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(message.utf8))
        exit(2)
    }

    static func label(_ kind: Limit.Kind) -> String { kind.model ?? "week" }

    /// Each account's readings, from a history file alone or from a folder of version 1.0.0's files,
    /// whose snapshots give the newest poll, through the reader the app uses. And the history file,
    /// beside which the moments are.
    static func read(_ path: String) throws -> (URL, [[Reading]]) {
        var folder: ObjCBool = false
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &folder), folder.boolValue else {
            return (url, try LegacyHistory.readings(history: Data(contentsOf: url), snapshots: nil))
        }
        let history = url.appending(path: "usage-history.json"), snapshots = url.appending(path: "usage-snapshots.json")
        let book = FileManager.default.fileExists(atPath: snapshots.path) ? try Data(contentsOf: snapshots) : nil
        return (history, try LegacyHistory.readings(history: Data(contentsOf: history), snapshots: book))
    }

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

    /// A named moment from `moments.json` beside the history file, a day and a time in the Mac's
    /// zone, or now, which name no account.
    static func moment(_ text: String, beside history: URL) -> (at: Date, label: String?, account: String?)? {
        if text == "now" { return (Date(), nil, nil) }
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

    /// Each account as the app says it at the moment: the Engine's verdicts, then its rows, its two
    /// sentences, its menu bar and any spent limit that is back, word for word.
    static func printMoment(_ at: Date, _ name: String?, _ accounts: [[Reading]]) {
        let zone = TimeZone.current
        let words = TimeWords(calendar: calendar(zone), now: at)
        for readings in accounts {
            guard let now = AccountNow(readings: readings, words: words) else {
                print("\(readings[0].account.rawValue): no reading at or before \(day(at, zone))")
                continue
            }
            print("\(name.map { "\($0). " } ?? "")Account \(now.account.rawValue) at \(day(at, zone)), "
                + "the reading of \(day(now.read, zone)). Times are \(zone.identifier).")
            if let picture = now.week?.picture {
                for (kind, meter) in [(Limit.Kind.week, picture.now.week)] + (picture.model.flatMap { kind in picture.now.model.map { (kind, $0) } }.map { [$0] } ?? []) {
                    guard let verdict = picture.verdicts[kind] else { continue }
                    print("  \(pad(label(kind), 5))  \(pad(percent(meter.used), 6))  \(said(verdict, zone))")
                }
            }
            for row in now.rows {
                switch row.state {
                case .read(let read):
                    print("  row    " + [row.title, "\(read.percent) used", read.resets, read.verdict].compactMap(\.self).joined(separator: " · ")
                        + "  (\(level(read.level)))")
                case .reset(_, let words):
                    print("  row    \(row.title) · \(words) · not read since")
                }
            }
            if let week = now.week {
                print("  says   \(week.sentences.forecast)")
                if let record = week.sentences.record { print("  shows  \(record)") }
            }
            print("  menu   \(now.menuBar.text)  (\(level(now.menuBar.level)), fill \(now.menuBar.left)%)  aloud: \(now.menuBar.spoken)")
            for back in now.back {
                print("  back   \(label(back.limit)), spent until \(day(back.spentUntil.instant, zone)), back by \(back.how == .reset ? "its reset" : "a banked reset")")
            }
        }
    }

    static func level(_ level: Level) -> String {
        switch level {
        case .plenty: "plenty"
        case .low: "low"
        case .nearlyGone: "nearly gone"
        }
    }

    // MARK: - For a person

    static func printText(_ path: String, _ forecasts: [Forecast], _ from: Date, _ kinds: [Limit.Kind], _ scores: [Score], _ account: Score,
                          _ end: Date) {
        let zone = TimeZone.current, since = from == .distantPast ? "" : " from \(day(from, zone))"
        print("The forecast at every poll of \(path)\(since)")
        print("Times are \(zone.identifier). \"then\" is what happened next; right or wrong once it is known.")
        print("\"says\" is the forecast's sentence for the account; \"shows\" is the record's.")
        for forecast in forecasts {
            let outcomes = kinds.map { forecast.outcomes(of: $0, recordEnd: end) }
            for (i, poll) in forecast.polls.enumerated() where poll.reading.at >= from {
                let head = [poll.reading.account.rawValue, day(poll.reading.at, zone)]
                for (k, kind) in kinds.enumerated() {
                    guard let verdict = poll.verdicts[kind], let used = poll.used[kind] else { continue }
                    let then = outcomes[k][i]
                    print((head + [pad(label(kind), 5), pad(percent(used.value), 6), pad(said(verdict, zone), 54), happened(then, zone), judged(verdict, then)])
                        .joined(separator: "  ").trimmingCharacters(in: .whitespaces))
                }
                let words = TimeWords(calendar: calendar(zone), now: poll.reading.at)
                guard let sentences = forecast.picture(at: poll.reading.at)?.sentences(in: words) else { continue }
                print((head + ["says ", sentences.forecast]).joined(separator: "  "))
                if let record = sentences.record { print((head + ["shows", record]).joined(separator: "  ")) }
            }
        }
        print("")
        let polls = forecasts.map { "\($0.polls.count { $0.reading.at >= from })" }.joined(separator: " + ")
        print("Score over \(polls) polls\(since); the record ends \(day(end, zone)).")
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

    static func printJSON(_ forecasts: [Forecast], _ from: Date, _ kinds: [Limit.Kind], _ scores: [Score], _ account: Score, _ end: Date) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func emit(_ value: some Encodable) { print(String(decoding: try! encoder.encode(value), as: UTF8.self)) }
        for forecast in forecasts {
            for poll in forecast.polls where poll.reading.at >= from {
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
                let sentences = forecast.picture(at: poll.reading.at)?.sentences(in: TimeWords(calendar: calendar(.current), now: poll.reading.at))
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
