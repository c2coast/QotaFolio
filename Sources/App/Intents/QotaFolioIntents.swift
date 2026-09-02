import AppIntents
import SwiftUI
import QotaFolioCore
import QotaFolioKit

/// How an intent reaches the running app's store and words. The composition root installs it
/// before `start()`; an intent that arrives while the app is still building waits here.
@MainActor
enum IntentServices {
    private(set) static var store: (any AccountsStoring)?
    private(set) static var catalog: (any AccountCataloging)?
    private(set) static var privacy: ScreenPrivacy?
    /// Which quantity the batteries are drawn to, so the rings in Spotlight's answer are drawn
    /// to it too.
    private(set) static var stripShows: StripPreferences?
    private static var waiters: [CheckedContinuation<Void, Never>] = []

    static func install(
        store: any AccountsStoring,
        catalog: any AccountCataloging,
        privacy: ScreenPrivacy?,
        stripShows: StripPreferences?
    ) {
        self.store = store
        self.catalog = catalog
        self.privacy = privacy
        self.stripShows = stripShows
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    static func ready() async {
        guard store == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// One account's row in the Spotlight snippet: the same ring the widget draws, the same rule
/// behind the numbers.
private struct QuotaSnippetRow: Identifiable {
    let id: AccountID
    let name: String
    let provider: AccountProvider
    let level: AccountLevel
}

private struct QuotaSnippetView: View {
    let rows: [QuotaSnippetRow]
    let showing: StripShows

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    QuotaRing(level: row.level, showing: showing, diameter: 30, showsNumber: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                            .font(.subheadline.weight(.semibold))
                        Text(levelText(row.level))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(12)
    }

    private func levelText(_ level: AccountLevel) -> String {
        switch level.state {
        case .reading, .low:
            return "\(level.sessionRemainingPercent)% now · \(level.weeklyRemainingPercent)% this week"
        case .spent:
            return String(localized: "Spent", comment: "An account with nothing left to spend now.")
        case .noReading(.needsSignIn):
            return String(localized: "Needs sign-in", comment: "An account whose grant has lapsed.")
        case .noReading(.waitingForFirstReading):
            return String(localized: "Waiting for its first reading", comment: "An account whose first reading has not arrived.")
        case .noReading(.setupIssue):
            return String(localized: "Setup issue", comment: "An account that cannot be polled until it is repaired.")
        case .noReading(.unavailable):
            return String(localized: "No reading", comment: "An account the provider answered nothing usable for.")
        }
    }
}

/// The words and rows one answer is made of, derived once for both intents.
@MainActor
private func quotaAnswer(matching entity: QuotaAccountEntity?) -> (dialog: String, rows: [QuotaSnippetRow])? {
    guard let store = IntentServices.store, let catalog = IntentServices.catalog else { return nil }
    let namesHidden = IntentServices.privacy?.isBlanketed ?? false
    var accounts = catalog.accounts
    if let entity {
        accounts = accounts.filter { $0.id == entity.id }
    }
    guard !accounts.isEmpty else { return nil }

    let strip = StatusStripModel.make(
        catalog: accounts,
        loadState: catalog.loadState,
        snapshots: store.snapshots,
        pollStatus: store.pollStatus,
        now: Date(),
        namesHidden: namesHidden
    )
    let rows = accounts.map { account in
        QuotaSnippetRow(
            id: account.id,
            name: presentedAccountName(account, namesHidden: namesHidden),
            provider: account.provider,
            level: AccountLevel.make(
                account: account,
                snapshot: store.snapshots[account.id],
                status: store.pollStatus[account.id]
            )
        )
    }
    let dialog = strip.cells
        .map { StatusStripModel.spokenSentence(for: $0) }
        .joined(separator: " ")
    return (dialog.isEmpty ? strip.accessibilityLabel : dialog, rows)
}

/// "How much do I have left?" — answered in place, in the strip's own sentences.
struct CheckQuotaIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Quota"
    static let description = IntentDescription(
        "Shows every account's current usage: what this session lets you spend, and what is left of each week."
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Account")
    var account: QuotaAccountEntity?

    // Every required parameter is in the summary — there are none — which is what puts the
    // action in Spotlight on macOS 26.
    static var parameterSummary: some ParameterSummary {
        Summary("Check quota for \(\.$account)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        await IntentServices.ready()
        guard let answer = quotaAnswer(matching: account) else {
            return .result(
                dialog: IntentDialog("No accounts yet. Open QotaFolio to add one."),
                view: QuotaSnippetView(rows: [], showing: IntentServices.stripShows?.shows ?? .session)
            )
        }
        return .result(
            dialog: IntentDialog("\(answer.dialog)"),
            view: QuotaSnippetView(rows: answer.rows, showing: IntentServices.stripShows?.shows ?? .session)
        )
    }
}

/// Polls every account now, waits for the readings, and answers with them.
struct RefreshAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh All Accounts"
    static let description = IntentDescription("Checks every account's usage with the provider right now.")
    static let supportedModes: IntentModes = .background

    static var parameterSummary: some ParameterSummary {
        Summary("Refresh every account")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        await IntentServices.ready()
        guard let store = IntentServices.store else {
            return .result(
                dialog: IntentDialog("QotaFolio is not running."),
                view: QuotaSnippetView(rows: [], showing: IntentServices.stripShows?.shows ?? .session)
            )
        }

        store.requestRefreshAll()
        // The refresh is the store's manual cycle; wait for it the way the footer's spinner
        // does, bounded — a provider that will not answer must not hang Spotlight.
        for _ in 0..<150 {
            if case .completed = store.manualRefresh { break }
            if store.manualRefresh == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        guard let answer = quotaAnswer(matching: nil) else {
            return .result(
                dialog: IntentDialog("No accounts yet. Open QotaFolio to add one."),
                view: QuotaSnippetView(rows: [], showing: IntentServices.stripShows?.shows ?? .session)
            )
        }
        return .result(
            dialog: IntentDialog("\(answer.dialog)"),
            view: QuotaSnippetView(rows: answer.rows, showing: IntentServices.stripShows?.shows ?? .session)
        )
    }
}

/// The three actions, available the moment the app is installed: Spotlight, Siri, Shortcuts.
struct QotaFolioShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CheckQuotaIntent(),
            phrases: [
                "Check my quota in \(.applicationName)",
                "How much do I have left in \(.applicationName)",
            ],
            shortTitle: "Check Quota",
            systemImageName: "battery.75percent"
        )
        AppShortcut(
            intent: RefreshAllIntent(),
            phrases: [
                "Refresh \(.applicationName)",
            ],
            shortTitle: "Refresh All",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: OpenQotaFolioIntent(),
            phrases: [
                "Open the \(.applicationName) panel",
            ],
            shortTitle: "Open Panel",
            systemImageName: "gauge.with.needle"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .orange
}
