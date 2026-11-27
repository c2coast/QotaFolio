import Foundation
import Kit
import Testing

/// What the app says of one account at one moment, on the frozen record in UTC. The verdicts are
/// `MomentsTests`' and the page's, the numbers the record's.
@Suite("The account now")
struct AccountNowTests {
    static func now(_ account: Int, at moment: Date, twelveHour: Bool = false) throws -> AccountNow {
        try #require(AccountNow(readings: Record.accounts[account], words: TimeWords(timeZone: Record.zone, twelveHour: twelveHour, now: moment)))
    }

    static func at(_ name: String) -> Date { Date(timeIntervalSince1970: Record.moments[name]!.at) }

    static func read(_ row: AccountNow.Row) throws -> AccountNow.Row.Read {
        guard case .read(let read) = row.state else { throw Unread(row: row.title) }
        return read
    }

    struct Unread: Error { let row: String }

    /// A, Tue 18 Nov 23:45. The poll of 23:42 reads the week at 15 and Fable at 12; the week runs out
    /// around Wed 19:15 and Fable is inside one step (`MomentsTests`), a silent verdict, which its
    /// row does not say. Both reset Wed 19 Nov 21:00.
    @Test("After a banked reset: each limit's reading, its reset with its day, and its verdict")
    func afterBankedReset() throws {
        let now = try Self.now(0, at: Self.at("after-banked-reset"))
        #expect(now.readWords == "Tue 23:42")
        #expect(now.rows.map(\.title) == ["Weekly", "Fable"])
        let week = try Self.read(now.rows[0]), fable = try Self.read(now.rows[1])
        #expect([week.percent, week.resets, week.verdict] == ["15%", "resets Wed 21:00", "runs out around Wed 19:15"])
        #expect([fable.percent, fable.resets, fable.verdict] == ["12%", "resets Wed 21:00", nil])
        #expect(week.level == .plenty)
        #expect(now.rows[0].spoken == "Weekly, 15% used, resets Wed 21:00, runs out around Wed 19:15.")
        #expect(now.week?.sentences.forecast == "At the last three hours’ pace, the week reaches its limit around Wed 19:15, 1h 45m before it resets.")
        #expect(now.week?.sentences.record == "A full banked reset at Tue 20:13 gave back 98 points.")
        #expect(now.menuBar == AccountNow.MenuBar(limit: .week, left: 85, level: .plenty, text: "85% left this week", spoken: "85 percent left this week"))
    }

    /// B, Thu 20 Nov 13:40: the week has read 100 since Tue 13:56 and resets Fri 21 Nov 13:00, and
    /// Fable reads 20, which nothing can spend until the week resets.
    @Test("A spent week: the week is spent, the model's week waits on it, and the menu bar says when it is back")
    func spentWeek() throws {
        let now = try Self.now(1, at: Self.at("spent-week"))
        let week = try Self.read(now.rows[0]), fable = try Self.read(now.rows[1])
        #expect([week.percent, week.resets, week.verdict] == ["100%", "resets Fri 13:00", "spent"])
        #expect([fable.percent, fable.verdict] == ["20%", "waits on the week"])
        #expect(week.level == .nearlyGone)
        #expect(now.menuBar == AccountNow.MenuBar(limit: .week, left: 0, level: .nearlyGone, text: "week spent, back Fri 13:00",
                                                  spoken: "week spent, back Fri 13:00"))
    }

    /// A, Wed 19 Nov 09:20. The poll of 09:17 reads the week at 54 and Fable at 29. At 4.26 points an
    /// hour the week's 46 points left last 10.8 hours, so it runs out around Wed 20:05, before both
    /// reset at 21:00. Fable at 3.71 an hour lands near 72 at the reset and lasts, but nothing is
    /// spent after the week runs out, so its row names the week and no time. The sentence is the
    /// week's, as before.
    @Test("When the week runs out first, the model's week's row says so and gives no time")
    func weekRunsOutFirst() throws {
        let now = try Self.now(0, at: Self.at("after-a-gap"))
        let week = try Self.read(now.rows[0]), fable = try Self.read(now.rows[1])
        #expect(week.verdict == "runs out around Wed 20:00")
        #expect([fable.percent, fable.resets, fable.verdict] == ["29%", "resets Wed 21:00", "the week runs out first"])
        #expect(now.rows[1].spoken == "Fable, 29% used, resets Wed 21:00, the week runs out first.")
        #expect(now.week?.sentences.forecast == "At the last three hours’ pace, the week reaches its limit around Wed 20:00, 1h 0m before it resets.")
    }

    /// A, Fri 14 Nov 00:35. The week at 98 runs out around 00:50, and Fable at 89 around 02:07, later:
    /// the week comes first. B, Fri 14 Nov 19:20: Fable at 73 runs out around 21:28, before the week
    /// at 23:26, so Fable keeps its own time.
    @Test("A model's week that runs out after the week names the week; one that runs out before keeps its time")
    func modelWeekAfterOrBefore() throws {
        let after = try Self.read(try Self.now(0, at: Self.at("out-in-15-minutes")).rows[1])
        #expect(after.verdict == "the week runs out first")
        let before = try Self.read(try Self.now(1, at: Self.at("fable-near-its-limit")).rows[1])
        #expect(before.verdict == "runs out around Fri 21:30")
    }

    /// A, Wed 19 Nov 21:02: the week reset at 21:00 and resets again Wed 26 Nov 21:00, seven days on.
    /// No use yet is silent: the row says nothing of it, and the sentence does.
    @Test("A reset seven days away says its date")
    func resetAWeekAway() throws {
        let now = try Self.now(0, at: Self.at("new-week-at-zero"))
        let week = try Self.read(now.rows[0])
        #expect([week.percent, week.resets, week.verdict] == ["0%", "resets Wed 26 Nov 21:00", nil])
        #expect(now.week?.sentences.forecast == "No use yet this week. It resets Wed 26 Nov 21:00.")
        #expect(try Self.now(0, at: Self.at("new-week-at-zero"), twelveHour: true).menuBar.text == "100% left this week")
    }

    /// A's last reading is Fri 21 Nov 14:28, with the week spent until Wed 26 Nov 21:00. At 20:55 that
    /// Wednesday the forecast still holds; at 21:05 the week has reset and nothing has been read.
    @Test("A moment after the week's reset, with no newer reading, says no forecast")
    func staleAfterReset() throws {
        let before = try Self.now(0, at: Record.moment(26, 20, 55))
        #expect(try Self.read(before.rows[0]).verdict == "spent")
        #expect(before.week?.picture != nil)
        #expect(before.week?.sentences.forecast == "Spent. Back Wed 21:00. Fable reads 99% and waits on the week.")

        let after = try Self.now(0, at: Record.moment(26, 21, 5))
        let reset = ResetTime(Record.moment(26, 21, 0))
        #expect(after.rows.map(\.state) == [.reset(at: reset, words: "reset Wed 21:00"), .reset(at: reset, words: "reset Wed 21:00")])
        #expect(after.rows[0].spoken == "Weekly, reset Wed 21:00, not read since.")
        #expect(after.week?.picture == nil)
        #expect(after.week?.sentences.forecast == "The week reset Wed 21:00, and has not been read since.")
        #expect(after.week?.sentences.record == nil)
        #expect(after.menuBar == AccountNow.MenuBar(limit: .week, left: 100, level: .plenty, text: "week reset Wed 21:00",
                                                    spoken: "week reset Wed 21:00, not read since"))
        #expect(after.readWords == "Fri 14:28")
    }

    /// A made-up account with a five-hour window, read Wed 3 Dec 2025 at 12:00: the session at 38,
    /// resetting Wed 14:00, and the week at 47, resetting Fri 13:00. The session gets its reading
    /// and its reset, and no forecast. The menu bar shows the week, with the session beside it.
    @Test("A five-hour row has its reading and its reset with its day, and no verdict")
    func fiveHour() throws {
        let session = Limit.Kind(model: nil, period: .session)
        let at = Self.december(3, 12, 0)
        let reading = Reading(account: AccountID("S"), at: at, limits: [
            Limit(kind: session, used: Percent(38)!, resets: ResetTime(Self.december(3, 14, 0))),
            Limit(kind: .week, used: Percent(47)!, resets: ResetTime(Self.december(5, 13, 0))),
        ])
        let now = try #require(AccountNow(readings: [reading], words: TimeWords(timeZone: Record.zone, now: at)))
        #expect(now.rows.map(\.title) == ["Weekly", "Session"])
        let row = try Self.read(now.rows[1])
        #expect([row.percent, row.resets] == ["38%", "resets Wed 14:00"])
        #expect(row.verdict == nil)
        #expect(now.rows[1].spoken == "Session, 38% used, resets Wed 14:00.")
        #expect(now.menuBar.text == "53% left this week, 62% this session")
        #expect(now.menuBar.spoken == "53 percent left this week, 62 percent this session")
    }

    /// A made-up account with a limit of thirty days and one of five hours on one model, read Wed 3
    /// Dec 2025 at 12:00. The row and the alert name each by its length in the same words.
    @Test("A limit of another length is named by its length, on the row and in the alert")
    func otherLength() throws {
        let month = Limit.Kind(model: nil, period: .other(seconds: 30 * 86400))
        let hours = Limit.Kind(model: "Codex", period: .other(seconds: 5 * 3600))
        let at = Self.december(3, 12, 0)
        let reading = Reading(account: AccountID("O"), at: at, limits: [
            Limit(kind: month, used: Percent(20)!, resets: ResetTime(Self.december(20, 0, 0))),
            Limit(kind: hours, used: Percent(10)!, resets: nil),
        ])
        let words = TimeWords(timeZone: Record.zone, now: at)
        let now = try #require(AccountNow(readings: [reading], words: words))
        #expect(now.rows.map(\.title) == ["30 days", "Codex, 5 hours"])
        let back = SpentLimitBack(account: AccountID("O"), limit: month, spentUntil: ResetTime(at), how: .reset)
        #expect(back.sentence(account: "Work", words: words) == "Work's limit of 30 days is back. It reset Wed 12:00.")
    }

    @Test("Before the first reading there is nothing to say")
    func beforeTheFirstReading() {
        #expect(AccountNow(readings: Record.accounts[0], words: TimeWords(timeZone: Record.zone, now: Record.moment(12, 14, 0))) == nil)
    }

    /// The account now runs the Engine on the week in force and the poll before it. At every poll
    /// of the record, its verdicts and sentences are the whole history's.
    @Test("On this week and the poll before it, every poll says what the whole history says", arguments: [0, 1])
    func lastWeekIsTheWhole(account: Int) throws {
        let whole = [Record.a, Record.b][account]
        for poll in whole.polls {
            let words = TimeWords(timeZone: Record.zone, now: poll.reading.at)
            let now = try #require(AccountNow(readings: Record.accounts[account], words: words))
            let picture = try #require(whole.picture(at: poll.reading.at))
            #expect(now.week?.sentences == picture.sentences(in: words), "\(Record.minute(poll.reading.at))")
            #expect(now.week?.picture?.verdicts == picture.verdicts, "\(Record.minute(poll.reading.at))")
            #expect(now.week?.picture?.points == picture.points, "\(Record.minute(poll.reading.at))")
        }
    }

    static func december(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Record.calendar.date(from: DateComponents(year: 2025, month: 12, day: day, hour: hour, minute: minute))!
    }
}
