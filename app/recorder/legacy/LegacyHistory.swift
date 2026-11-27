import Foundation
import Kit

/// Version 1.0.0's two books of usage, read into each account's readings: the trace,
/// `usage-history.json`, and the last poll of each account, `usage-snapshots.json`.
///
/// A pure function of the books' bytes: the caller reads the files, or encodes the books it holds
/// in memory as the files are, so the app, `qota` and `tools/forecast` read the same readings.
///
/// The trace keeps each limit's samples and the reset time of the occurrence now open, and not
/// the reset in force at each sample. So that reset is rebuilt here, as the forecast's method
/// rebuilds it. A week's reset is moved back a whole week at a time from its minute until the
/// sample falls inside its week. Occurrences of any other period do not run back to back, so a
/// sample before the open one has no reset.
///
/// A reading joins the samples of one second. Version 1.0.0 spaces each limit's samples on its own,
/// so a model's week missed by one poll is sampled at other seconds than the week from then on.
/// Each reading keeps the limits sampled at its time, and the Engine reads the model's week from
/// the readings that carry it.
///
/// The trace keeps a sample a quarter-hour after the last at most, so it usually lacks the newest
/// poll. The snapshot is that poll, with each reset as the provider sent it, and it is the last
/// reading when it is newer than the trace.
public enum LegacyHistory {
    public struct Unreadable: Error, CustomStringConvertible {
        public let description: String
    }

    /// One array for each account, each in time order: the trace's accounts in its order, then any
    /// account only the snapshots hold. With no snapshots, the trace alone.
    public static func readings(history: Data, snapshots: Data?) throws -> [[Reading]] {
        var accounts = try decode(TraceBook.self, history, "a usage history").accounts.map(trace).filter { !$0.isEmpty }
        guard let snapshots else { return accounts }
        for snapshot in try decode(SnapshotBook.self, snapshots, "a snapshot book").accounts {
            let newest = try snapshot.reading()
            if let k = accounts.firstIndex(where: { $0[0].account == newest.account }) {
                if newest.at > accounts[k][accounts[k].count - 1].at { accounts[k].append(newest) }
            } else {
                accounts.append([newest])
            }
        }
        return accounts
    }

    private static func decode<Book: Decodable & Versioned>(_ type: Book.Type, _ data: Data, _ what: String) throws -> Book {
        let book: Book
        do {
            book = try JSONDecoder().decode(Book.self, from: data)
        } catch {
            throw Unreadable(description: "not \(what) of version 1.0.0: \(error)")
        }
        guard book.schemaVersion == 1 else {
            throw Unreadable(description: "\(what) of schema version \(book.schemaVersion); version 1.0.0 wrote 1")
        }
        return book
    }

    private static func trace(_ account: TraceBook.Account) throws -> [Reading] {
        let id = AccountID(account.account.rawValue)
        var limits: [Int: [Limit]] = [:]
        for window in account.windows {
            guard window.sampleTimes.count == window.sampleUsedBasisPoints.count else {
                throw Unreadable(description: "\(id.rawValue) \(window.key): times and amounts differ in number")
            }
            for (t, basisPoints) in zip(window.sampleTimes, window.sampleUsedBasisPoints) {
                guard let used = Percent(basisPoints: basisPoints) else {
                    throw Unreadable(description: "\(id.rawValue) \(window.key) at \(t): \(basisPoints) is not 0 to 10000")
                }
                limits[t, default: []].append(Limit(kind: window.period.kind(window.scope), used: used, resets: window.reset(inForceAt: t)))
            }
        }
        return limits.keys.sorted().map { t in
            Reading(account: id, at: Date(timeIntervalSince1970: TimeInterval(t)), limits: limits[t]!)
        }
    }
}

private let week: TimeInterval = 7 * 86400

private protocol Versioned {
    var schemaVersion: Int { get }
}

private struct ID: Decodable { let rawValue: String }

/// A limit's period as version 1.0.0 encodes it: `{"weekly":{}}`, `{"session":{}}` or
/// `{"other":{"seconds":n}}`.
private enum Period: Decodable {
    case weekly
    case session
    case other(seconds: Double)

    func kind(_ scope: String?) -> Limit.Kind {
        switch self {
        case .weekly: Limit.Kind(model: scope, period: .week)
        case .session: Limit.Kind(model: scope, period: .session)
        case .other(let seconds): Limit.Kind(model: scope, period: .other(seconds: seconds))
        }
    }
}

private struct TraceBook: Decodable, Versioned {
    let schemaVersion: Int
    let accounts: [Account]

    struct Account: Decodable {
        let account: ID
        let windows: [Window]
    }

    struct Window: Decodable {
        let key: String
        /// The model a limit counts, absent for a limit on every model.
        let scope: String?
        let period: Period
        let sampleTimes: [Int]
        let sampleUsedBasisPoints: [Int]
        let currentOpenedAt: Int
        let currentResetsAt: Int?

        func reset(inForceAt t: Int) -> ResetTime? {
            guard let current = currentResetsAt else { return nil }
            let open = ResetTime(Date(timeIntervalSince1970: TimeInterval(current)))
            guard case .weekly = period else { return t >= currentOpenedAt ? open : nil }
            var r = open.instant
            while r.timeIntervalSince1970 - week > TimeInterval(t) { r -= week }
            return ResetTime(r)
        }
    }
}

private struct SnapshotBook: Decodable, Versioned {
    let schemaVersion: Int
    let accounts: [Snapshot]

    /// The last successful poll of one account, whole, as the provider answered it.
    struct Snapshot: Decodable {
        let account: ID
        let fetchedAt: Int
        let readings: [Entry]

        /// One limit as the provider answered it.
        struct Entry: Decodable {
            let scope: String?
            let period: Period
            let usedPercent: Double
            let resetsAt: Int?
        }

        /// The poll as a reading. Its percents are held in hundredths and clamped to 0 to 100, as
        /// version 1.0.0 writes them into the trace, so the snapshot reads as the trace would.
        func reading() throws -> Reading {
            let id = AccountID(account.rawValue)
            let limits = try readings.map { entry in
                let basisPoints = Int(max(0, min(10_000, (entry.usedPercent * 100).rounded())))
                guard let used = Percent(basisPoints: basisPoints) else {
                    throw LegacyHistory.Unreadable(description: "\(id.rawValue) snapshot: \(entry.usedPercent) is not a percent")
                }
                return Limit(kind: entry.period.kind(entry.scope), used: used,
                             resets: entry.resetsAt.map { ResetTime(Date(timeIntervalSince1970: TimeInterval($0))) })
            }
            return Reading(account: id, at: Date(timeIntervalSince1970: TimeInterval(fetchedAt)), limits: limits)
        }
    }
}
