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
