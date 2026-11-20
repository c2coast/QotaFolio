import Foundation
import Kit
import Testing

@Suite("The week picture")
struct PictureTests {
    /// A provider sends the new week's reset as 20:59:59 a week on, and a reset time is the nearest
    /// minute, so that week starts at 21:00:00. A live poll at 20:59:59 already carries it.
    @Test("A poll a second before its week's start is in its own picture")
    func pollBeforeItsWeek() throws {
        let start = Record.moment(19, 21, 0)
        func reading(_ at: Date, week: Double, fable: Double, resets: Date) -> Reading {
            Reading(account: AccountID("A"), at: at, limits: [
                Limit(kind: .week, used: Percent(week)!, resets: ResetTime(resets)),
                Limit(kind: Record.fable, used: Percent(fable)!, resets: ResetTime(resets)),
            ])
        }
        let poll = start - 1
        let forecast = Forecast(readings: [
            reading(start - 900, week: 90, fable: 40, resets: start),
            reading(poll, week: 0, fable: 0, resets: start + 7 * 86400 - 1),
        ])
        let picture = try #require(forecast.picture(at: poll))
        #expect(picture.resets.instant == start + 7 * 86400)
        #expect(picture.points.map(\.at) == [poll])
        #expect(picture.start <= poll)
    }
}
