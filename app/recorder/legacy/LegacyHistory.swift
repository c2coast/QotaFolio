import Foundation
import Kit

/// Version 1.0.0's usage history, the file `usage-history.json`, read into readings.
///
/// A pure function of the file's bytes: the caller reads the file. Version 1.0.0 keeps each limit's
/// samples and the reset time of the occurrence now open, and not the reset in force at each
/// sample. So that reset is rebuilt here, as the forecast's method rebuilds it. A week's reset is
/// moved back a whole week at a time from its minute until the sample falls inside its week.
/// Occurrences of any other period do not run back to back, so a sample before the open one has no
/// reset.
///
/// A reading joins the samples of one second, and the Engine reads a model's week only where every
/// reading carries it. So a file whose model's week was sampled at other seconds than the week is
/// refused, rather than read as an account with no model's week.
public enum LegacyHistory {
    public struct Unreadable: Error, CustomStringConvertible {
        public let description: String
    }

    /// One array for each account in the file, in the file's order, each in time order. A reading
    /// holds every limit sampled at its time.
    public static func readings(from data: Data) throws -> [[Reading]] {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw Unreadable(description: "not a usage history of version 1.0.0: \(error)")
        }
        guard file.schemaVersion == 1 else {
            throw Unreadable(description: "schema version \(file.schemaVersion); version 1.0.0 wrote 1")
        }
        return try file.accounts.map { account in
            let id = AccountID(account.account.rawValue)
            if let week = account.windows.first(where: { $0.kind == .week }),
               let off = account.windows.first(where: { $0.kind.model != nil && $0.kind.period == .week && $0.sampleTimes != week.sampleTimes }) {
                throw Unreadable(description: "\(id.rawValue) \(off.key): sampled at other times than the week, \(week.key)")
            }
            var limits: [Int: [Limit]] = [:]
            for window in account.windows {
                guard window.sampleTimes.count == window.sampleUsedBasisPoints.count else {
                    throw Unreadable(description: "\(id.rawValue) \(window.key): times and amounts differ in number")
                }
                for (t, basisPoints) in zip(window.sampleTimes, window.sampleUsedBasisPoints) {
                    guard let used = Percent(basisPoints: basisPoints) else {
                        throw Unreadable(description: "\(id.rawValue) \(window.key) at \(t): \(basisPoints) is not 0 to 10000")
                    }
                    limits[t, default: []].append(Limit(kind: window.kind, used: used, resets: window.reset(inForceAt: t)))
                }
            }
            return limits.keys.sorted().map { t in
                Reading(account: id, at: Date(timeIntervalSince1970: TimeInterval(t)), limits: limits[t]!)
            }
        }
    }
}

private let week: TimeInterval = 7 * 86400

private struct File: Decodable {
    let schemaVersion: Int
    let accounts: [Account]
}

private struct Account: Decodable {
    struct ID: Decodable { let rawValue: String }
    let account: ID
    let windows: [Window]
}

private struct Window: Decodable {
    /// As version 1.0.0 encodes it: `{"weekly":{}}`, `{"session":{}}` or `{"other":{"seconds":n}}`.
    enum Period: Decodable {
        case weekly
        case session
        case other(seconds: Double)
    }

    let key: String
    /// The model a limit counts, absent for a limit on every model.
    let scope: String?
    let period: Period
    let sampleTimes: [Int]
    let sampleUsedBasisPoints: [Int]
    let currentOpenedAt: Int
    let currentResetsAt: Int?

    var kind: Limit.Kind {
        switch period {
        case .weekly: Limit.Kind(model: scope, period: .week)
        case .session: Limit.Kind(model: scope, period: .session)
        case .other(let seconds): Limit.Kind(model: scope, period: .other(seconds: seconds))
        }
    }

    func reset(inForceAt t: Int) -> ResetTime? {
        guard let current = currentResetsAt else { return nil }
        let open = ResetTime(Date(timeIntervalSince1970: TimeInterval(current)))
        guard case .weekly = period else { return t >= currentOpenedAt ? open : nil }
        var r = open.instant
        while r.timeIntervalSince1970 - week > TimeInterval(t) { r -= week }
        return ResetTime(r)
    }
}
