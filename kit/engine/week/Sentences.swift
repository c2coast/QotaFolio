import Foundation

/// The two sentences under the graph: what the forecast says, and the record's one sentence.
public struct Sentences: Hashable, Sendable {
    /// What the forecast says. When the week is spent, it also says what the model's week reads.
    public let forecast: String
    /// The latest thing the graph shows that a number alone would not. None when there is nothing.
    public let record: String?
}

extension WeekPicture {
    /// The sentences, word for word as the chart page says them on a 24-hour clock. Every time
    /// carries its day, said as the words say a time. A run-out time at or before the moment the
    /// words are said is left out, because nothing newer was read to say whether it came.
    public func sentences(in words: TimeWords) -> Sentences {
        let said = Said(time: words, picture: self)
        return Sentences(forecast: said.forecast(), record: said.record())
    }
}

private struct Said {
    let time: TimeWords
    let picture: WeekPicture

    /// The model's name, such as "Fable".
    var name: String { picture.model?.model ?? "" }

    var reset: Double { picture.resets.instant.timeIntervalSince1970 }

    func forecast() -> String {
        let back = day(reset)
        switch picture.forecast {
        case .spent:
            let held = picture.now.model.map { " \(name) reads \(Whole.percent($0.used))% and waits on the week." } ?? ""
            return "Spent. Back \(back).\(held)"
        case .notStarted:
            return "No use yet this week. It resets \(back)."
        case .modelSpent(let week):
            switch week {
            case .runsOut(let at, _, _) where passed(at):
                return "\(name) is spent until \(back)."
            case .runsOut(let at, _, let speed):
                return "\(name) is spent until \(back). \(pace(speed)), other models reach the week’s limit around \(time.quarterDay(at))."
            case .lasts(let landing, _, let speed):
                return "\(name) is spent until \(back). \(pace(speed)), the week lasts to then with \(left(landing))."
            case .spent, .silent:
                return "\(name) is spent until \(back). The week is too close to call."
            }
        case .silent:
            return "Too early to say — the range is wider than a number would be honest about."
        case .runsOut(let first, let at, let speed, _) where first == .week:
            return passed(at) ? unread() : weekRunsOut(at, speed)
        case .runsOut(_, let at, _, let week) where passed(at):
            switch week {
            case .runsOut(let weekAt, _, let speed)?: return passed(weekAt) ? unread() : weekRunsOut(weekAt, speed)
            case .lasts(let landing, _, let speed)?: return "\(pace(speed)), the week lasts to its reset \(back) with \(left(landing))."
            case .spent?, .silent?, nil: return "The week is too close to call."
            }
        case .runsOut(_, let at, let speed, let week):
            let then = switch week {
            case .runsOut(let weekAt, _, _): "and the week around \(time.quarterDay(weekAt))"
            case .lasts(let landing, _, _): "while the week lasts to \(back) with \(left(landing))"
            case .spent, .silent, nil: "and the week is too close to call"
            }
            return "\(pace(speed)), \(name) reaches its limit around \(time.quarterDay(at)), \(then)."
        case .lasts(let landing, let modelLanding, let speed):
            let model = modelLanding.map { ", and \(name) with about \(Whole.left($0))%" } ?? ""
            return "\(pace(speed)), the week lasts to its reset \(back) with \(left(landing))\(model)."
        }
    }

    func weekRunsOut(_ at: Date, _ speed: Verdict.Speed) -> String {
        let before = countdown(Int(reset - TimeWords.quarterHour(at).timeIntervalSince1970))
        return "\(pace(speed)), the week reaches its limit around \(time.quarterDay(at)), \(before) before it resets."
    }

    /// Whether a run-out time has come by the moment the words are said.
    func passed(_ at: Date) -> Bool { at <= time.now }

    /// Every run-out time has passed, and no reading since says whether it came.
    func unread() -> String { "Nothing has been read since \(time.day(picture.now.at)), so there is no forecast." }

    /// The latest of the record's events; at a spent week, how long it has been at the limit.
    func record() -> String? {
        var latest: (at: Double, said: String)?
        func add(_ at: Double, _ said: String) {
            if latest.map({ at >= $0.at }) ?? true { latest = (at, said) }
        }
        for fall in picture.falls {
            let before = fall.before.at.timeIntervalSince1970, after = fall.after.at.timeIntervalSince1970
            let unwatched = after - before > WeekPicture.gapSeconds
            let what = "gave back \(points(fall.givenBack[.week] ?? 0))\(unwatched ? " or more" : "")"
            switch fall.kind {
            case .full, .model:
                let kind = fall.kind == .full ? "A full banked reset" : "A \(name) banked reset"
                add(after, unwatched
                    ? "\(kind) fell between \(day(before)) and \(day(after)), while nobody watched; it \(what)."
                    : "\(kind) at \(day(after)) \(what).")
            case .unexplained:
                add(after, unwatched
                    ? "Between \(day(before)) and \(day(after)), while nobody watched, the week \(what); the readings do not say why."
                    : "At \(day(after)) the week \(what); the readings do not say why.")
            }
        }
        for gap in picture.gaps where gap.fall == nil {
            let rose = gap.after.week.work - gap.before.week.work
            if rose < 1 { continue }
            let to = gap.after.at.timeIntervalSince1970
            add(to, "Not watched from \(day(gap.before.at.timeIntervalSince1970)) to \(day(to)); the week rose \(points(rose)) in that time.")
        }
        let now = picture.now.at
        for stretch in picture.atLimit where stretch.duration > secondsPerHour {
            let from = stretch.start.timeIntervalSince1970
            add(from + 1, stretch.end >= now
                ? "At the limit since \(day(from))."
                : "At the limit from \(day(from)) to \(day(stretch.end.timeIntervalSince1970)).")
        }
        if let lead = picture.unrecorded {
            let to = lead.end.timeIntervalSince1970
            add(to - 1, "Nothing was recorded before \(day(to)), when the week already read \(Whole.percent(picture.points[0].week.used))%.")
        }
        if picture.spent, let stretch = picture.atLimit.last {
            return "At the limit since \(day(stretch.start.timeIntervalSince1970))."
        }
        return latest?.said
    }

    func pace(_ speed: Verdict.Speed) -> String {
        speed == .weekPace ? "At this week’s pace" : "At the last three hours’ pace"
    }

    func left(_ landing: Double) -> String { "about \(Whole.left(landing))% left" }

    /// "Wed 19:15": the day and the time to the minute, as the page's `dc`.
    func day(_ seconds: Double) -> String { time.day(Date(timeIntervalSince1970: seconds)) }
}

/// "12 points", "1 point", as the page's `pts`.
private func points(_ n: Double) -> String {
    let k = Whole.points(n)
    return "\(k) \(k == 1 ? "point" : "points")"
}

/// "3d 16h", "1h 45m", "15m", "<1m": the time left, as the page's `countdown`.
private func countdown(_ seconds: Int) -> String {
    if seconds < 60 { return "<1m" }
    let d = seconds / 86400, h = seconds % 86400 / 3600, m = seconds % 3600 / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}
