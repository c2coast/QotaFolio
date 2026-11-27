extension SpentLimitBack {
    /// Every limit the newest of an account's readings, in time order, finds back: a limit it reads
    /// below 100 that the latest earlier reading carrying that limit read at 100 with a reset. The
    /// trace samples each limit on its own spacing, so the reading just before the newest may not
    /// carry the limit at all. A limit that was not spent is never back, and a limit the newest
    /// reading does not carry is found when a reading carries it again.
    public static func newest(in readings: some BidirectionalCollection<Reading>) -> [SpentLimitBack] {
        guard let newest = readings.last else { return [] }
        let earlier = readings.dropLast()
        return newest.limits.compactMap { now in
            guard now.used.value < 100,
                  let spent = earlier.last(where: { $0.limit(now.kind) != nil })?.limit(now.kind),
                  spent.used.value >= 100, let until = spent.resets else { return nil }
            let reset = newest.at >= until.instant || now.resets != until
            return SpentLimitBack(account: newest.account, limit: now.kind, spentUntil: until, how: reset ? .reset : .banked)
        }
    }
}

extension SpentLimitBack {
    /// What the alert says, the account named by the app: "Personal's week is back. It reset
    /// Wed 21:00." A banked reset: "Personal's week is back early. A banked reset gave its points
    /// back before Wed 21:00."
    public func sentence(account name: String, words: TimeWords) -> String {
        let until = words.day(spentUntil.instant)
        switch how {
        case .reset: return "\(name)'s \(subject) is back. It reset \(until)."
        case .banked: return "\(name)'s \(subject) is back early. A banked reset gave its points back before \(until)."
        }
    }

    /// "week", "Fable week", "session", "limit of 30 days".
    private var subject: String {
        let model = limit.model.map { "\($0) " } ?? ""
        switch limit.period {
        case .week: return model + "week"
        case .session: return model + "session"
        case .other(let seconds):
            let days = Int((seconds / 86400).rounded()), hours = Int((seconds / 3600).rounded())
            return model + "limit of " + (days >= 1 ? "\(days) \(days == 1 ? "day" : "days")" : "\(hours) \(hours == 1 ? "hour" : "hours")")
        }
    }
}
