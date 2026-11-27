import Kit

/// The menu bar's strip: a battery for each account in the panel's order, what VoiceOver reads, and
/// the tooltip, made together from Kit's value so the picture, the voice and the hover never
/// disagree. Each account's battery and words are its `AccountNow.MenuBar`: the week by default.
public nonisolated struct Strip: Hashable, Sendable {
    public let batteries: [Battery]
    /// "QotaFolio.", then one sentence for each account.
    public let spoken: String
    /// One line for each account.
    public let tooltip: String

    /// What the strip has to say of one account.
    public nonisolated enum Account: Sendable {
        /// The account as Kit says it now.
        case now(name: String, AccountNow)
        /// An account with nothing to draw, and the line and sentence that say why, such as
        /// "Spare — needs sign-in" and "Spare needs sign-in.": the outline alone, at the quiet weight.
        case quiet(line: String, sentence: String)
    }

    /// The strip of the accounts. With `session`, an account with an open session draws that
    /// session's share instead of the week's; the words say both either way.
    public init(_ accounts: [Account], session: Bool) {
        batteries = accounts.map { account in
            guard case .now(_, let now) = account else { return Battery(fill: nil) }
            return Battery(fill: session ? Battery.session(now) ?? Battery.week(now) : Battery.week(now))
        }
        spoken = (["QotaFolio."] + accounts.map { account in
            switch account {
            case .now(let name, let now): "\(name): \(now.menuBar.spoken)."
            case .quiet(_, let sentence): sentence
            }
        }).joined(separator: " ")
        tooltip = accounts.map { account in
            switch account {
            case .now(let name, let now): "\(name) \(now.menuBar.text)"
            case .quiet(let line, _): line
            }
        }.joined(separator: "\n")
    }

    /// A strip with no battery to draw and one sentence to say: the item stays on the bar as one
    /// empty outline, something to click, and the voice and the hover say why.
    public init(saying message: String) {
        batteries = []
        spoken = "QotaFolio. \(message)"
        tooltip = message
    }
}

/// One account's battery.
public nonisolated struct Battery: Hashable, Sendable {
    /// What the fill is drawn to. None for an account with no reading: the outline alone.
    public let fill: Fill?

    public nonisolated struct Fill: Hashable, Sendable {
        /// The whole percent left, 0 to 100: the fill's length. At 0, Apple's residual hairline.
        public let left: Int
        public let level: Level
    }

    static func week(_ now: AccountNow) -> Fill {
        Fill(left: now.menuBar.left, level: now.menuBar.level)
    }

    /// The account-wide session's own share, while it is read and open.
    static func session(_ now: AccountNow) -> Fill? {
        let row = now.rows.first { $0.limit == Limit.Kind(model: nil, period: .session) }
        guard case .read(let read)? = row?.state else { return nil }
        return Fill(left: Whole.left(read.used.value), level: read.level)
    }
}
