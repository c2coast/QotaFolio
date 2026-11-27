import Foundation
import Kit
import QotaFolioModel
import Testing

/// The two books filled as the app fills them, one poll at a time, and read back as the app, `qota`
/// and `tools/forecast` read them.
@Suite("The books the app keeps")
struct BooksTests {
    /// Polls three minutes apart. The trace keeps the week a quarter-hour apart and the session at
    /// every poll, so most polls leave a session alone in the trace, and the snapshot is the whole
    /// poll. The app records each poll a moment after the provider answered it, and a trace stamped
    /// at that moment, a second after the snapshot, left the week off the newest reading. Both books
    /// now keep the time the poll was read.
    @Test("The newest reading carries the week")
    func newestCarriesTheWeek() throws {
        let account = QotaFolioModel.AccountID(rawValue: UUID())
        let start = Date(timeIntervalSince1970: 1_764_000_000)
        var traces = UsageTraceBook(), snapshots = UsageSnapshotBook()
        for k in 0..<7 {
            let read = start + Double(k) * 180
            let snapshot = UsageSnapshot(
                provider: .anthropic,
                session: UsageWindow(usedPercent: 10 + Double(k), resetsAt: start + 4 * 3600, severity: nil),
                weekly: UsageWindow(usedPercent: 40 + Double(k), resetsAt: start + 3 * 86400, severity: nil),
                fable: nil,
                fetchedAt: read
            )
            snapshots.record(PersistedUsageSnapshot(account: account, snapshot: snapshot))
            traces.observe(snapshot, for: account)
        }
        let readings = try LegacyHistory.readings(history: UsageHistoryCodec.encode(traces, for: .traces),
                                                  snapshots: UsageHistoryCodec.encode(snapshots, for: .snapshots))
        let newest = try #require(readings.first?.last)
        #expect(newest.at == start + 6 * 180)
        #expect(newest.limit(.week)?.used == Percent(46))
        #expect(newest.limit(Limit.Kind(model: nil, period: .session))?.used == Percent(16))
    }
}
