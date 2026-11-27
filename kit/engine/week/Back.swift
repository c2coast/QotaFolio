import Foundation

extension SpentLimitBack {
    /// Every limit that `before` read at 100 percent with a reset and `after` finds back: read
    /// below 100, or, when `after` does not read it, past its reset. A limit that was not spent is
    /// never back.
    public static func between(_ before: Reading, _ after: Reading) -> [SpentLimitBack] {
        before.limits.compactMap { spent in
            guard spent.used.value >= 100, let until = spent.resets else { return nil }
            let now = after.limit(spent.kind)
            let reset = after.at >= until.instant || (now.map { $0.resets != until } ?? false)
            if let now, now.used.value >= 100 { return nil }
            if now == nil && !reset { return nil }
            return SpentLimitBack(account: before.account, limit: spent.kind, spentUntil: until, how: reset ? .reset : .banked)
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
