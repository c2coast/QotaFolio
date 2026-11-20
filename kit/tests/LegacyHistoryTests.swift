import Foundation
import Kit
import Testing

@Suite("The reader of version 1.0.0's history")
struct LegacyHistoryTests {
    @Test("The record reads as two accounts of 289 polls, each with the week and Fable")
    func record() {
        #expect(Record.accounts.map { $0.first?.account.rawValue } == ["A", "B"])
        #expect(Record.accounts.map(\.count) == [289, 289])
        #expect(Record.accounts.map { Record.minute($0.first!.at) } == ["Wed 12 Nov 14:12", "Wed 12 Nov 14:16"])
        #expect(Record.accounts.map { Record.minute($0.last!.at) } == ["Fri 21 Nov 14:28", "Fri 21 Nov 14:31"])
        #expect(Record.accounts.joined().allSatisfy { $0.limits.map(\.kind) == [.week, Record.fable] })
    }

    /// Version 1.0.0 kept only the reset of the week now open. For A the file holds it as the
    /// provider sent it, Wed 26 Nov 20:59:59, and it reads as the minute, 21:00. A poll two weeks
    /// earlier is placed by moving that minute back a week at a time: Wed 12 Nov 21:00.
    @Test("A sample's reset is the open week's minute, moved back whole weeks")
    func resetsMovedBack() throws {
        let data = try Data(contentsOf: Record.fixtures.appending(path: "usage-history.json"))
        let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let accounts = try #require(file["accounts"] as? [[String: Any]])
        let windows = try #require(accounts.first?["windows"] as? [[String: Any]])
        #expect(windows.first?["currentResetsAt"] as? Int == Int(Record.moment(26, 20, 59, 59).timeIntervalSince1970))

        let first = try #require(Record.accounts[0].first?.limit(.week)?.resets)
        let last = try #require(Record.accounts[0].last?.limit(.week)?.resets)
        #expect(first.instant == Record.moment(12, 21, 0))
        #expect(last.instant == Record.moment(26, 21, 0))
    }

    @Test("A reading over 100 percent is refused where it enters")
    func refusesOverOneHundred() {
        let file = """
            {"schemaVersion": 1, "accounts": [{"account": {"rawValue": "A"}, "lastRecordedAt": 100, "windows": [
              {"key": "weekly", "period": {"weekly": {}}, "sampleTimes": [100], "sampleUsedBasisPoints": [14000],
               "completed": [], "currentOpenedAt": 0, "currentResetsAt": 604800, "lastObservedAt": 100}]}]}
            """
        #expect(throws: LegacyHistory.Unreadable.self) { try LegacyHistory.readings(from: Data(file.utf8)) }
    }

    /// The Engine reads a model's week only where every reading carries it. Read on, this file
    /// would give a forecast with no Fable, and nobody would be told.
    @Test("A model's week sampled at other times than the week is refused, by its name")
    func refusesModelWeekOffTheWeek() {
        let file = """
            {"schemaVersion": 1, "accounts": [{"account": {"rawValue": "A"}, "lastRecordedAt": 250, "windows": [
              {"key": "weekly", "period": {"weekly": {}}, "sampleTimes": [100, 200], "sampleUsedBasisPoints": [100, 200],
               "completed": [], "currentOpenedAt": 0, "currentResetsAt": 604800, "lastObservedAt": 200},
              {"key": "Fable|weekly", "scope": "Fable", "period": {"weekly": {}}, "sampleTimes": [100, 250],
               "sampleUsedBasisPoints": [100, 300], "completed": [], "currentOpenedAt": 0, "currentResetsAt": 604800,
               "lastObservedAt": 250}]}]}
            """
        let error = #expect(throws: LegacyHistory.Unreadable.self) { try LegacyHistory.readings(from: Data(file.utf8)) }
        #expect(error?.description.contains("Fable|weekly") == true)
    }
}
