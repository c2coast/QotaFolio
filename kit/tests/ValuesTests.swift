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
}
