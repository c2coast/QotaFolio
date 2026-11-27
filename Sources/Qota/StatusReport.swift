import Foundation
import Kit
import QotaFolioModel

/// What `qota status` prints, decided from the files and nothing else.
///
/// Who, in what order and under what name comes from the catalog and the snapshots, as
/// `SurfaceReading` reads them. What each account says comes from Kit: its readings, read from the
/// history and the snapshots by the reader the app uses, said at the moment the command runs as
/// `AccountNow`. So each row is the card's row, word for word.
nonisolated enum StatusReport {
    /// The document `--json` prints.
    struct Document: Codable, Equatable, Sendable {
        struct Row: Codable, Equatable, Sendable {
            /// "Weekly", "Fable", "Session".
            let title: String
            /// What the newest reading read. Absent once the limit's reset has passed.
            let usedPercent: Double?
            let resetsAt: Date?
            /// The verdict in a few words, "runs out around Thu 19:15", for the week and the
            /// model's week.
            let verdict: String?
            /// The row in one line, as the text form prints it.
            let said: String
        }

        struct Account: Codable, Equatable, Sendable {
            /// The account's UUID as a plain string — a shell script's `jq` should not have to
            /// know that the app's own files spell it as an object.
            let id: String
            let name: String
            let provider: AccountProvider
            let plan: String?
            let order: Int
            let needsSignIn: Bool
            let observedAt: Date?
            let rows: [Row]
        }

        let schemaVersion: Int
        let generatedAt: Date?
        let accounts: [Account]
    }

    static let schemaVersion = 2

    /// Each account the reading holds, with what Kit says of it now. None for an account with no
    /// reading yet.
    static func said(_ reading: SurfaceReading, _ readings: [[Reading]], words: TimeWords) -> [(SurfaceAccount, AccountNow?)] {
        reading.accounts.map { account in
            let own = readings.first { $0.first?.account == Kit.AccountID(account.id.rawValue.uuidString) }
            return (account, own.flatMap { AccountNow(readings: $0, words: words) })
        }
    }

    static func document(_ accounts: [(SurfaceAccount, AccountNow?)], newest: [[Reading]], observedAt: Date?) -> Document {
        Document(
            schemaVersion: schemaVersion,
            generatedAt: observedAt,
            accounts: accounts.map { account, now in
                let last = newest.first { $0.first?.account == now?.account }?.last
                return Document.Account(
                    id: account.id.rawValue.uuidString,
                    name: account.name,
                    provider: account.provider,
                    plan: account.planName,
                    order: account.order,
                    needsSignIn: account.needsSignIn,
                    observedAt: account.observedAt,
                    rows: (now?.rows ?? []).map { row in
                        let read: AccountNow.Row.Read? = if case .read(let read) = row.state { read } else { nil }
                        return Document.Row(
                            title: row.title,
                            usedPercent: read?.used.value,
                            resetsAt: last?.limit(row.limit)?.resets?.instant,
                            verdict: read?.verdict,
                            said: row.spoken
                        )
                    }
                )
            }
        )
    }

    static func json(_ document: Document) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// The human form: one block per account, one line per limit, a footer with the age.
    static func text(_ accounts: [(SurfaceAccount, AccountNow?)], observedAt: Date?, words: TimeWords) -> String {
        var lines: [String] = []
        for (account, now) in accounts {
            var heading = account.name + " (" + providerName(account.provider)
            if let plan = account.planName, !plan.isEmpty { heading += " · " + plan }
            heading += ")"
            lines.append(heading)
            if let now {
                lines += now.rows.map { "  " + $0.spoken }
                if account.needsSignIn {
                    lines.append("  needs sign-in — the numbers above are the last known, of \(now.readWords)")
                }
            } else {
                lines.append("  " + stateLine(account.level))
            }
            lines.append("")
        }
        if let observedAt {
            lines.append("Updated \(words.day(observedAt)) (\(age(of: observedAt, now: words.now)))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Pieces

    static func providerName(_ provider: AccountProvider) -> String {
        switch provider {
        case .anthropic: "Claude"
        case .openai: "ChatGPT"
        }
    }

    static func stateLine(_ level: AccountLevel) -> String {
        switch level.state {
        case .noReading(.needsSignIn): "needs sign-in"
        case .noReading(.waitingForFirstReading): "waiting for its first reading"
        case .noReading(.setupIssue): "setup issue"
        case .noReading(.unavailable): "no reading"
        case .reading, .low, .spent: "no limits reported"
        }
    }

    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3_600) h ago" }
        return "\(seconds / 86_400) d ago"
    }
}
