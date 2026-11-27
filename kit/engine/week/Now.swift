import Foundation

extension AccountNow {
    /// The account at the moment the words are said, `words.now`, from its readings in time order.
    /// None before its first reading of any limit.
    ///
    /// The Engine reads the week of the poll in force and the poll before it, and nothing older,
    /// so the cost is one week's whatever the history holds. A forecast for a week whose reset has
    /// passed is not said: the rows say the reset, and the week has no picture.
    public init?(readings: [Reading], words: TimeWords) {
        let now = words.now
        var end = readings.startIndex, high = readings.endIndex
        while end < high {
            let mid = (end + high) / 2
            if readings[mid].at <= now { end = mid + 1 } else { high = mid }
        }
        let known = readings[..<end]
        guard let newest = known.last, !newest.limits.isEmpty else { return nil }
        let forecast = Forecast(readings: Array(Self.lastWeek(of: known)))
        let poll = forecast.poll(at: now)
        let reset = poll.map { now >= $0.resets.instant } ?? false
        let verdicts = poll.flatMap { !reset && $0.reading.at == newest.at ? $0.verdicts : nil } ?? [:]
        let said = Said(words: words, weekSpent: (newest.limit(.week)?.used.value ?? 0) >= 100, week: verdicts[.week])

        let limits = Self.order(newest.limits)
        let rows = limits.map { said.row($0, verdicts[$0.kind], now: now) }
        let week: Week? = forecast.picture(at: now).map { picture in
            reset ? Week(picture: nil, sentences: Sentences(forecast: said.weekReset(picture.resets), record: nil))
                : Week(picture: picture, sentences: picture.sentences(in: words))
        }
        self.init(account: newest.account, read: newest.at, readWords: words.day(newest.at), rows: rows, week: week,
                  menuBar: said.menuBar(limits, now: now))
    }

    /// The readings of the week in force at the last of them, with the reading of the week before
    /// that last carries the week. Every verdict and picture of that week is the same as on the
    /// whole history, because the Engine reads no further back. It is found from the end, so its
    /// cost is the week's.
    static func lastWeek(of readings: ArraySlice<Reading>) -> ArraySlice<Reading> {
        guard let p = readings.lastIndex(where: { $0.limit(.week)?.resets != nil }) else { return readings }
        let start = min(readings[p].limit(.week)!.resets!.instant - secondsPerWeek, readings[p].at)
        guard let outside = readings[..<p].lastIndex(where: { $0.at < start }) else { return readings }
        return readings[(readings[...outside].lastIndex { $0.limit(.week)?.resets != nil } ?? outside + 1)...]
    }

    /// The week first, then each model's week, then the rest as the reading has them.
    static func order(_ limits: [Limit]) -> [Limit] {
        func rank(_ limit: Limit) -> Int { limit.kind == .week ? 0 : limit.kind.period == .week ? 1 : 2 }
        return limits.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

/// The words of the rows and the menu bar.
private struct Said {
    let words: TimeWords
    let weekSpent: Bool
    /// The week's verdict at the poll, which a model's week's row reads.
    let week: Verdict?

    func row(_ limit: Limit, _ verdict: Verdict?, now: Date) -> AccountNow.Row {
        let name = title(limit.kind)
        if let resets = limit.resets, now >= resets.instant {
            let reset = "reset \(words.day(resets.instant))"
            return AccountNow.Row(limit: limit.kind, title: name, state: .reset(at: resets, words: reset), spoken: "\(name), \(reset), not read since.")
        }
        let read = AccountNow.Row.Read(used: limit.used, level: Level(used: limit.used.value), percent: "\(Whole.percent(limit.used.value))%",
                                       resets: limit.resets.map { "resets \(words.day($0.instant))" },
                                       verdict: verdict.map { self.verdict($0, limit) })
        let spoken = [name, "\(read.percent) used", read.resets, read.verdict].compactMap(\.self).joined(separator: ", ") + "."
        return AccountNow.Row(limit: limit.kind, title: name, state: .read(read), spoken: spoken)
    }

    func verdict(_ verdict: Verdict, _ limit: Limit) -> String {
        if limit.kind != .week, limit.kind.period == .week, weekFirst(before: verdict) { return "the week runs out first" }
        return switch verdict {
        case .spent: limit.kind != .week && weekSpent && limit.used.value < 100 ? "waits on the week" : "spent"
        case .silent(.notStarted): "no use yet"
        case .silent(.noClockYet): "too early to say"
        case .silent(.insideOneStep): "too close to call"
        case .runsOut(let at, _, _): "runs out around \(words.quarterDay(at))"
        case .lasts(let landing, _, _): "lasts with about \(Whole.left(landing))% left"
        }
    }

    /// Whether the week's verdict has the week run out before a model's week's own verdict ends:
    /// it runs out, and the model's week lasts or runs out no earlier. There the model's week's
    /// own time was right about half the time on the frozen record, and wrong by days, because
    /// its outcome falls past a spent week and a banked reset that no pace sees. Elsewhere it is
    /// as good as the week's. So its row says the week comes first, with no time.
    func weekFirst(before verdict: Verdict) -> Bool {
        guard case .runsOut(let week, _, _)? = self.week else { return false }
        switch verdict {
        case .lasts: return true
        case .runsOut(let at, _, _): return week <= at
        case .spent, .silent: return false
        }
    }

    func weekReset(_ reset: ResetTime) -> String {
        "The week reset \(words.day(reset.instant)), and has not been read since."
    }

    /// The week, or the first limit of an account with no week, and a session beside it while one
    /// is open.
    func menuBar(_ limits: [Limit], now: Date) -> AccountNow.MenuBar {
        let limit = limits[0], what = subject(limit.kind), span = span(limit.kind.period)
        if let resets = limit.resets, now >= resets.instant {
            let reset = "\(what) reset \(words.day(resets.instant))"
            return AccountNow.MenuBar(limit: limit.kind, left: 100, level: Level(used: 0), text: reset, spoken: "\(reset), not read since")
        }
        if limit.used.value >= 100 {
            let spent = "\(what) spent" + (limit.resets.map { ", back \(words.day($0.instant))" } ?? "")
            return AccountNow.MenuBar(limit: limit.kind, left: 0, level: Level(used: limit.used.value), text: spent, spoken: spent)
        }
        let left = Whole.left(limit.used.value)
        let session = limits.dropFirst().first { other in
            other.kind == Limit.Kind(model: nil, period: .session) && other.resets.map { now < $0.instant } ?? true
        }.map { Whole.left($0.used.value) }
        return AccountNow.MenuBar(limit: limit.kind, left: left, level: Level(used: limit.used.value),
                                  text: "\(left)% left \(span)" + (session.map { ", \($0)% this session" } ?? ""),
                                  spoken: "\(left) percent left \(span)" + (session.map { ", \($0) percent this session" } ?? ""))
    }

    /// How the menu bar names the limit it shows: "week", "session", or the row's title.
    func subject(_ kind: Limit.Kind) -> String {
        switch (kind.model, kind.period) {
        case (nil, .week): "week"
        case (nil, .session): "session"
        default: title(kind)
        }
    }

    /// "Week", "Fable", "Session", "Fable session", "30 days".
    func title(_ kind: Limit.Kind) -> String {
        switch (kind.model, kind.period) {
        case (nil, .week): "Week"
        case (let model?, .week): model
        case (nil, .session): "Session"
        case (let model?, .session): "\(model) session"
        case (let model, .other(let seconds)): (model.map { "\($0), " } ?? "") + TimeWords.length(seconds)
        }
    }

    func span(_ period: Limit.Period) -> String {
        switch period {
        case .week: "this week"
        case .session: "this session"
        case .other: "until it resets"
        }
    }
}
