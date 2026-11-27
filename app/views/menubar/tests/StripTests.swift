import Foundation
import Kit
import Testing

/// The menu bar's strip on made-up readings, worked by hand. One reading at noon on Mon 2 Mar 2026
/// UTC: the week at 47 used, so 53 left, plenty; and for one account a session at 62 used, so 38
/// left, low.
@Suite("The menu bar's strip")
struct StripTests {
    static let noon = Date(timeIntervalSince1970: 1_772_452_800)

    static func account(_ name: String, session: Bool) throws -> Strip.Account {
        var limits = [Limit(kind: .week, used: Percent(47)!, resets: ResetTime(noon + 3 * 86_400))]
        if session { limits.append(Limit(kind: Limit.Kind(model: nil, period: .session), used: Percent(62)!, resets: ResetTime(noon + 7_200))) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try #require(AccountNow(readings: [Reading(account: AccountID(name), at: noon, limits: limits)],
                                          words: TimeWords(timeZone: calendar.timeZone, now: noon + 60)))
        return .now(name: name, now)
    }

    @Test("An account with no session says its week alone, and draws its week whichever is chosen")
    func weekOnly() throws {
        let spare = try Self.account("Spare", session: false)
        for session in [false, true] {
            let strip = Strip([spare], session: session)
            #expect(strip.batteries == [Battery(fill: Battery.Fill(left: 53, level: .plenty))])
            #expect(strip.spoken == "QotaFolio. Spare: 53 percent left this week.")
            #expect(strip.tooltip == "Spare 53% left this week")
        }
    }

    @Test("The week is drawn by default; chosen, an open session is drawn, and the words say both")
    func session() throws {
        let personal = try Self.account("Personal", session: true)
        #expect(Strip([personal], session: false).batteries == [Battery(fill: Battery.Fill(left: 53, level: .plenty))])
        let strip = Strip([personal], session: true)
        #expect(strip.batteries == [Battery(fill: Battery.Fill(left: 38, level: .low))])
        #expect(strip.spoken == "QotaFolio. Personal: 53 percent left this week, 38 percent this session.")
        #expect(strip.tooltip == "Personal 53% left this week, 38% this session")
    }

    @Test("An account with no reading is the outline alone, with the words it is handed")
    func quiet() throws {
        let strip = Strip([try Self.account("Personal", session: true), .quiet(line: "Spare — needs sign-in", sentence: "Spare needs sign-in.")],
                          session: false)
        #expect(strip.batteries.map(\.fill?.left) == [53, nil])
        #expect(strip.spoken == "QotaFolio. Personal: 53 percent left this week, 38 percent this session. Spare needs sign-in.")
        #expect(strip.tooltip == "Personal 53% left this week, 38% this session\nSpare — needs sign-in")
    }
}
