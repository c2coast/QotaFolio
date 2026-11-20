import Foundation
import Kit
import Testing

@Suite("The values")
struct ValuesTests {
    @Test("A percent is made only from 0 to 100")
    func percentBounds() {
        #expect(Percent(140) == nil)
        #expect(Percent(-1) == nil)
        #expect(Percent(.nan) == nil)
        #expect(Percent(basisPoints: 14000) == nil)
        #expect(Percent(basisPoints: 10000)?.value == 100)
        #expect(Percent(basisPoints: 6700)?.value == 67)
    }

    /// Version 1.0.0's file named account A's week reset a second before its Fable week's, as the
    /// provider sent them: the frozen record holds 1764190799 beside 1764190800.
    @Test("Reset times one second apart are one time")
    func resetTimesOneSecondApart() throws {
        let last = try #require(Record.accounts[0].last)
        let week = try #require(last.limit(.week)?.resets)
        let fable = try #require(last.limit(Record.fable)?.resets)
        #expect(week.instant.timeIntervalSince1970 == 1_764_190_799)
        #expect(fable.instant.timeIntervalSince1970 == 1_764_190_800)
        #expect(week == fable)
        #expect(Set([week, fable]).count == 1)
        #expect(ResetTime(Date(timeIntervalSince1970: 1_764_190_800)) != ResetTime(Date(timeIntervalSince1970: 1_764_190_920)))
    }

    /// The case where it matters: A's full banked reset on Tue 18 Nov at 20:13. If the poll after
    /// it named the week's reset a second later than the poll before it, an Engine that compared
    /// seconds would take the fall for the week's own reset: it would find no fall there, and give
    /// back nothing.
    @Test("A reset named a second later does not end the week")
    func jitterKeepsTheWeek() throws {
        let readings = Record.accounts[0]
        let after = try #require(readings.firstIndex { Record.minute($0.at) == "Tue 18 Nov 20:13" })
        let reading = readings[after]
        let moved = reading.limits.map { limit in
            guard limit.kind == .week, let resets = limit.resets else { return limit }
            return Limit(kind: limit.kind, used: limit.used, resets: ResetTime(resets.instant + 1))
        }
        var jittered = readings
        jittered[after] = Reading(account: reading.account, at: reading.at, limits: moved)

        let forecast = Forecast(readings: jittered)
        #expect(forecast.falls.map(\.kind) == [.model, .full, .model])
        #expect(forecast.polls[after].givenBack[.week] == 144.5)
    }
}
