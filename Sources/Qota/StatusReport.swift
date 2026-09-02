import Foundation
import QotaFolioModel

/// What `qota status` prints, decided from the three files and nothing else.
///
/// A pure function over the files: the reading (who, in what order, what each holds) and the
/// recommendation document (the row texts the app rendered, and the instant they were true).
/// No policy is linked and no word is computed twice — the row text is the file's.
nonisolated enum StatusReport {
    /// The document `--json` prints. The recommendation file's shape minus its directive fields
    /// (`pick`, the plan sentence): the app is informational, and so is its command.
    struct Document: Codable, Equatable, Sendable {
        struct Window: Codable, Equatable, Sendable {
            let key: String
            let scope: String?
            let title: String
            let usedPercent: Double
            let resetsAt: Date?
            /// The right-hand text the panel's instrument shows for this window, as the app
            /// rendered it. Absent when the app has not assessed this window.
            let detail: String?
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
            let windows: [Window]
        }

        let schemaVersion: Int
        let generatedAt: Date?
        let accounts: [Account]
    }

    static let schemaVersion = 1

    /// The document, from the reading and the recommendation file when there is one.
    static func document(reading: SurfaceReading, recommendation: RecommendationDocument?) -> Document {
        Document(
            schemaVersion: schemaVersion,
            generatedAt: recommendation?.generatedAt ?? reading.observedAt,
            accounts: reading.accounts.map { account in
                Document.Account(
                    id: account.id.rawValue.uuidString,
                    name: account.name,
                    provider: account.provider,
                    plan: account.planName,
                    order: account.order,
                    needsSignIn: account.needsSignIn,
                    observedAt: account.observedAt,
                    windows: titledWindows(account.windows).map { window, title in
                        Document.Window(
                            key: window.id,
                            scope: window.scope,
                            title: title,
                            usedPercent: window.usedPercent,
                            resetsAt: window.resetsAt,
                            detail: rowText(recommendation, account: account.id, window: window.id)
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

    /// The human form: one block per account, one line per window, a footer with the age.
    static func text(
        reading: SurfaceReading,
        recommendation: RecommendationDocument?,
        now: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var lines: [String] = []
        for account in reading.accounts {
            var heading = account.name + " (" + providerName(account.provider)
            if let plan = account.planName, !plan.isEmpty { heading += " · " + plan }
            heading += ")"
            lines.append(heading)

            let windows = titledWindows(account.windows)
            if windows.isEmpty {
                lines.append("  " + stateLine(account.level))
            } else {
                let titleWidth = windows.map(\.title.count).max() ?? 0
                for (window, title) in windows {
                    var row = "  " + title.padding(toLength: titleWidth + 2, withPad: " ", startingAt: 0)
                    row += String(window.wholePercentUsed).leftPadded(to: 3) + "% used"
                    if let resetsAt = window.resetsAt {
                        if resetsAt <= now {
                            // The reset has passed and no fresh reading has arrived: the
                            // panel's words for this moment, not yesterday's clock time.
                            row += "   reset due"
                        } else {
                            row += "   resets " + clock(resetsAt, now: now, locale: locale, calendar: calendar, timeZone: timeZone)
                            row += " · " + countdown(to: resetsAt, from: now)
                        }
                    }
                    if let detail = rowText(recommendation, account: account.id, window: window.id), !detail.isEmpty {
                        row += "   " + detail
                    }
                    lines.append(row)
                }
                if account.needsSignIn {
                    lines.append("  needs sign-in — the numbers above are the last known")
                }
            }
            lines.append("")
        }

        if let observed = reading.observedAt {
            let updated = observed.formatted(
                Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
            )
            lines.append("Updated \(updated) (\(age(of: observed, now: now)))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Pieces

    /// What each row is called: the provider's own name, or the app's word for the window's
    /// length; a name that would draw two rows takes the window word after it.
    static func titledWindows(_ windows: [SurfaceWindow]) -> [(window: SurfaceWindow, title: String)] {
        var counts = [String: Int]()
        for window in windows { if let scope = window.scope { counts[scope, default: 0] += 1 } }
        return windows.map { window in
            guard let scope = window.scope else { return (window, lengthName(window.period)) }
            guard counts[scope, default: 0] > 1 else { return (window, scope) }
            return (window, "\(scope) \(lengthName(window.period))")
        }
    }

    static func lengthName(_ period: UsagePeriod) -> String {
        switch period {
        case .session: return "Session"
        case .weekly: return "Weekly"
        case .other(let seconds):
            let bounded = seconds.isFinite ? min(max(0, seconds), 31_622_400) : 0
            return Duration.seconds(bounded).formatted(
                .units(allowed: [.weeks, .days, .hours, .minutes], width: .wide, maximumUnitCount: 1)
            )
        }
    }

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
        case .reading, .low, .spent: "no windows reported"
        }
    }

    static func rowText(_ recommendation: RecommendationDocument?, account: AccountID, window: String) -> String? {
        recommendation?.accounts.first { $0.id == account }?.windows.first { $0.key == window }?.detail
    }

    /// The reset as a clock: the time alone inside a day, the weekday and time beyond it.
    static func clock(_ date: Date, now: Date, locale: Locale, calendar: Calendar, timeZone: TimeZone) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone)
        if date.timeIntervalSince(now) < 20 * 3_600 {
            return date.formatted(style)
        }
        return date.formatted(style.weekday(.abbreviated))
    }

    /// "1h 5m", "2d 3h", "12m", "<1m", or "due" once the instant has passed.
    static func countdown(to date: Date, from now: Date) -> String {
        let interval = date.timeIntervalSince(now)
        guard interval.isFinite, interval > 0 else { return "due" }
        let seconds = Int(interval)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "in \(days)d \(hours)h" }
        if hours > 0 { return "in \(hours)h \(minutes)m" }
        if minutes > 0 { return "in \(minutes)m" }
        return "in <1m"
    }

    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(seconds / 60) min ago" }
        if seconds < 86_400 { return "\(seconds / 3_600) h ago" }
        return "\(seconds / 86_400) d ago"
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
