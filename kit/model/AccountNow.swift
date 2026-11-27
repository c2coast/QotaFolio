import Foundation

/// Everything the app says of one account at one moment: a row for each limit of the newest
/// reading, the week as the graph draws it with its two sentences, and the menu bar's week. The card, the menu bar, VoiceOver and `qota status` lay it out, and
/// none of them words a limit, a number or a time of its own.
///
/// Kit builds it from the account's readings and the time words, which carry the moment. The
/// account's name is the app's; the words here follow it.
public struct AccountNow: Sendable {
    public let account: AccountID
    /// When the newest reading at or before the moment was read.
    public let read: Date
    /// That time in the time words, "Thu 23:45", as the card's "As of" says it.
    public let readWords: String
    /// One for each limit of the newest reading: the week first, then the model's week, then the
    /// rest in the reading's order.
    public let rows: [Row]
    /// The week and its sentences, or why there is none.
    public let week: Week
    public let menuBar: MenuBar

    public init(account: AccountID, read: Date, readWords: String, rows: [Row], week: Week, menuBar: MenuBar) {
        precondition(!rows.isEmpty, "an account now reads at least one limit")
        self.account = account
        self.read = read
        self.readWords = readWords
        self.rows = rows
        self.week = week
        self.menuBar = menuBar
    }

    /// One limit of the newest reading.
    public struct Row: Hashable, Sendable {
        public let limit: Limit.Kind
        /// "Weekly", "Fable", "Session".
        public let title: String
        public let state: State
        /// The row in one line, for VoiceOver and `qota`: "Weekly, 38% used, resets Fri 13:00, runs out
        /// around Thu 19:15."
        public let spoken: String

        public init(limit: Limit.Kind, title: String, state: State, spoken: String) {
            (self.limit, self.title, self.state, self.spoken) = (limit, title, state, spoken)
        }

        public enum State: Hashable, Sendable {
            /// As the newest reading read it.
            case read(Read)
            /// Its reset has passed since the newest reading. By the provider's rule it is back to
            /// zero, and nothing has been read of it since. The words: "reset Wed 21:00".
            case reset(at: ResetTime, words: String)
        }

        public struct Read: Hashable, Sendable {
            public let used: Percent
            public let level: Level
            /// The whole percent used, "38%".
            public let percent: String
            /// "resets Fri 13:00". None when the provider named no reset.
            public let resets: String?
            /// The verdict in a few words, "runs out around Thu 19:15", for the week and the model's
            /// week when the Engine speaks. None while it is silent, for a limit of any other
            /// period, and once the week has reset.
            public let verdict: String?

            public init(used: Percent, level: Level, percent: String, resets: String?, verdict: String?) {
                (self.used, self.level, self.percent, self.resets, self.verdict) = (used, level, percent, resets, verdict)
            }
        }
    }

    /// The week as the graph draws it, and the two sentences under it. With no picture, the first
    /// sentence says why, and there is no second.
    public struct Week: Sendable {
        /// None once the week has reset with nothing read since: nothing of the new week is known,
        /// and last week's is no longer true. None too when no reading carries the week with its
        /// reset.
        public let picture: WeekPicture?
        public let sentences: Sentences

        public init(picture: WeekPicture?, sentences: Sentences) {
            (self.picture, self.sentences) = (picture, sentences)
        }
    }

    /// The menu bar's part for the account: the week, or the first limit of an account with none.
    public struct MenuBar: Hashable, Sendable {
        public let limit: Limit.Kind
        /// The whole percent left, 0 to 100, which the battery fills. All of it once the limit has
        /// reset with nothing read since.
        public let left: Int
        public let level: Level
        /// What follows the account's name in the tooltip: "53% left this week".
        public let text: String
        /// What follows the account's name aloud: "53 percent left this week".
        public let spoken: String

        public init(limit: Limit.Kind, left: Int, level: Level, text: String, spoken: String) {
            (self.limit, self.left, self.level, self.text, self.spoken) = (limit, left, level, text, spoken)
        }
    }
}
