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
        #expect(throws: LegacyHistory.Unreadable.self) { try LegacyHistory.readings(history: Data(file.utf8), snapshots: nil) }
    }

    /// Version 1.0.0 spaces each limit's samples on its own: here the week at 100 and 200, Fable at
    /// 100 and 250. The file reads as one account, with a reading at each time and the limits
    /// sampled at it.
    @Test("A model's week sampled at other times than the week reads, each reading with its own limits")
    func modelWeekOffTheWeek() throws {
        let file = """
            {"schemaVersion": 1, "accounts": [{"account": {"rawValue": "A"}, "lastRecordedAt": 250, "windows": [
              {"key": "weekly", "period": {"weekly": {}}, "sampleTimes": [100, 200], "sampleUsedBasisPoints": [100, 200],
               "completed": [], "currentOpenedAt": 0, "currentResetsAt": 604800, "lastObservedAt": 200},
              {"key": "Fable|weekly", "scope": "Fable", "period": {"weekly": {}}, "sampleTimes": [100, 250],
               "sampleUsedBasisPoints": [100, 300], "completed": [], "currentOpenedAt": 0, "currentResetsAt": 604800,
               "lastObservedAt": 250}]}]}
            """
        let accounts = try LegacyHistory.readings(history: Data(file.utf8), snapshots: nil)
        #expect(accounts.count == 1)
        let readings = try #require(accounts.first)
        #expect(readings.map(\.at.timeIntervalSince1970) == [100, 200, 250])
        #expect(readings.map { $0.limits.map(\.kind) } == [[.week, Record.fable], [.week], [Record.fable]])
        #expect(readings[2].limit(Record.fable)?.used == Percent(3))
    }

    /// A trace of the week and Fable at 100 and 200, and a snapshot of the poll at 250: the week at
    /// 3.456 percent, which 1.0.0 holds as 346 hundredths, Fable at 120, which it holds as 100, and a
    /// five-hour window with no session open. The trace's open week resets at 604800; the snapshot
    /// sends the week's reset a second early, 604799, which is the same minute.
    static let trace = """
        {"schemaVersion": 1, "accounts": [{"account": {"rawValue": "A"}, "lastRecordedAt": 200, "windows": [
          {"key": "weekly", "period": {"weekly": {}}, "sampleTimes": [100, 200], "sampleUsedBasisPoints": [100, 200],
           "completed": [], "currentOpenedAt": 0, "currentResetsAt": 604800, "lastObservedAt": 200},
          {"key": "Fable|weekly", "scope": "Fable", "period": {"weekly": {}}, "sampleTimes": [100, 200],
           "sampleUsedBasisPoints": [100, 300], "completed": [], "currentOpenedAt": 0, "currentResetsAt": 604800,
           "lastObservedAt": 200}]}]}
        """

    static func snapshots(at fetchedAt: Int, account: String = "A") -> String {
        """
        {"schemaVersion": 1, "accounts": [{"account": {"rawValue": "\(account)"}, "provider": "anthropic", "fetchedAt": \(fetchedAt),
          "readings": [
            {"period": {"session": {}}, "usedPercent": 0},
            {"period": {"weekly": {}}, "usedPercent": 3.456, "resetsAt": 604799, "severity": "normal"},
            {"period": {"weekly": {}}, "scope": "Fable", "usedPercent": 120, "resetsAt": 604800}]}]}
        """
    }

    @Test("The snapshot is the last reading, read as the trace would hold it")
    func snapshotLast() throws {
        let accounts = try LegacyHistory.readings(history: Data(Self.trace.utf8), snapshots: Data(Self.snapshots(at: 250).utf8))
        let readings = try #require(accounts.first)
        #expect(accounts.count == 1)
        #expect(readings.map(\.at.timeIntervalSince1970) == [100, 200, 250])
        let last = try #require(readings.last)
        #expect(last.limits.map(\.kind) == [Limit.Kind(model: nil, period: .session), .week, Record.fable])
        #expect(last.limit(.week)?.used == Percent(basisPoints: 346))
        #expect(last.limit(Record.fable)?.used == Percent(100))
        #expect(last.limit(.week)?.resets == readings[1].limit(.week)?.resets)
        #expect(last.limit(Limit.Kind(model: nil, period: .session))?.resets == nil)
    }

    /// The trace kept the poll of 200 itself, so the snapshot of that poll adds no reading. It is
    /// the reading of 200, because it holds every limit of the poll.
    @Test("A snapshot of the trace's last second adds no reading, and is that reading")
    func snapshotHeld() throws {
        let accounts = try LegacyHistory.readings(history: Data(Self.trace.utf8), snapshots: Data(Self.snapshots(at: 200).utf8))
        #expect(accounts.map { $0.map(\.at.timeIntervalSince1970) } == [[100, 200]])
        #expect(accounts[0][1].limits.map(\.kind) == [Limit.Kind(model: nil, period: .session), .week, Record.fable])
    }

    /// A poll of an account with a five-hour window: the trace keeps its session at 200, and its
    /// week only a quarter-hour after 100. The reading of 200 is the snapshot's, with the week.
    @Test("The newest poll keeps the limits the trace spaced out of it")
    func snapshotWhole() throws {
        let trace = """
            {"schemaVersion": 1, "accounts": [{"account": {"rawValue": "A"}, "lastRecordedAt": 200, "windows": [
              {"key": "weekly", "period": {"weekly": {}}, "sampleTimes": [100], "sampleUsedBasisPoints": [100],
               "completed": [], "currentOpenedAt": 0, "currentResetsAt": 604800, "lastObservedAt": 200},
              {"key": "session", "period": {"session": {}}, "sampleTimes": [100, 200], "sampleUsedBasisPoints": [0, 0],
               "completed": [], "currentOpenedAt": 0, "lastObservedAt": 200}]}]}
            """
        let accounts = try LegacyHistory.readings(history: Data(trace.utf8), snapshots: Data(Self.snapshots(at: 200).utf8))
        let readings = try #require(accounts.first)
        #expect(readings.map(\.at.timeIntervalSince1970) == [100, 200])
        #expect(readings[1].limit(.week)?.used == Percent(basisPoints: 346))
    }

    /// An account added since the trace was last written has its first poll only.
    @Test("An account only the snapshots hold reads as its one poll")
    func snapshotOnly() throws {
        let accounts = try LegacyHistory.readings(history: Data(Self.trace.utf8), snapshots: Data(Self.snapshots(at: 250, account: "C").utf8))
        #expect(accounts.map { $0[0].account.rawValue } == ["A", "C"])
        #expect(accounts[1].count == 1)
    }
}
