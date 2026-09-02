import QotaFolioModel
import SwiftUI

// The widget's faces and their words, compiled into the extension AND the app: WidgetKit
// renders them on the desktop, and the fixture runtime hosts the very same views in its own
// window so they can be photographed on a Mac where nobody may touch the widget gallery.

/// Rings in a grid: two columns, up to three rows, drawn to the same quantity the menu-bar
/// batteries are, with that quantity's number inside each.
struct SmallFleetView: View {
    let reading: SurfaceReading
    let now: Date

    var body: some View {
        let accounts = Array(reading.accounts.prefix(qotaFolioMaximumAccounts))
        let columns = accounts.count == 1 ? 1 : 2
        let rows = (accounts.count + columns - 1) / columns
        GeometryReader { proxy in
            let cell = min(proxy.size.width / CGFloat(columns), proxy.size.height / CGFloat(rows))
            let ring = cell - 6
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: columns), spacing: 0) {
                ForEach(accounts) { account in
                    QuotaRing(level: account.level, showing: reading.stripShows, diameter: ring, showsNumber: true)
                        .frame(width: cell, height: cell)
                        .accessibilityLabel(spokenSentence(for: account, namesHidden: reading.namesHidden))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// One row per account: the ring, the name, the two numbers, the next reset.
struct MediumFleetView: View {
    let reading: SurfaceReading
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(reading.accounts) { account in
                HStack(spacing: 10) {
                    QuotaRing(level: account.level, showing: reading.stripShows, diameter: 28, showsNumber: false)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(presentedName(for: account, namesHidden: reading.namesHidden))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(levelSentence(for: account.level))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let reset = nextResetText(for: account) {
                        reset
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenSentence(for: account, namesHidden: reading.namesHidden))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The soonest reset ahead as a live countdown WidgetKit ticks itself; "Reset due" once it
    /// has passed and no fresh reading has arrived — the panel's own words for the same moment.
    private func nextResetText(for account: SurfaceAccount) -> Text? {
        let resets = account.windows.compactMap(\.resetsAt)
        guard !resets.isEmpty else { return nil }
        if let ahead = resets.filter({ $0 > now }).min() {
            return Text("resets in \(ahead, style: .relative)", comment: "A live countdown to the next reset.")
        }
        return Text("Reset due", comment: "Shown when a reset time has passed and fresh numbers have not arrived.")
    }
}

// MARK: - Words

/// The account's name, or its provider while names are hidden.
nonisolated func presentedName(for account: SurfaceAccount, namesHidden: Bool) -> String {
    guard namesHidden else { return account.name }
    switch account.provider {
    case .anthropic:
        return String(localized: "Anthropic account", comment: "Stands in for an Anthropic account's name while account names are hidden.")
    case .openai:
        return String(localized: "ChatGPT account", comment: "Stands in for a ChatGPT account's name while account names are hidden.")
    }
}

/// "53% now · 71% this week", or the state's own sentence.
nonisolated func levelSentence(for level: AccountLevel) -> String {
    switch level.state {
    case .reading, .low:
        return String(
            localized: "\(level.sessionRemainingPercent)% now · \(level.weeklyRemainingPercent)% this week",
            comment: "One account's level: what it lets you spend now, and what is left of its week."
        )
    case .spent:
        return String(localized: "Spent", comment: "An account with nothing left to spend now.")
    case .noReading(.waitingForFirstReading):
        return String(localized: "Waiting for its first reading", comment: "An account whose first reading has not arrived.")
    case .noReading(.needsSignIn):
        return String(localized: "Needs sign-in", comment: "An account whose grant has lapsed.")
    case .noReading(.unavailable):
        return String(localized: "No reading", comment: "An account the provider answered nothing usable for.")
    case .noReading(.setupIssue):
        return String(localized: "Setup issue", comment: "An account that cannot be polled until it is repaired.")
    }
}

/// One sentence per account for VoiceOver, in the strip's own form.
nonisolated func spokenSentence(for account: SurfaceAccount, namesHidden: Bool) -> String {
    let name = presentedName(for: account, namesHidden: namesHidden)
    switch account.level.state {
    case .reading, .low:
        return String(
            localized: "\(name): \(account.level.sessionRemainingPercent) percent available now, \(account.level.weeklyRemainingPercent) percent left this week.",
            comment: "Spoken sentence for one account: what it lets you spend now, and what is left of its week."
        )
    case .spent:
        return String(localized: "\(name) spent.", comment: "Spoken sentence for a spent account.")
    case .noReading:
        return "\(name): \(levelSentence(for: account.level))."
    }
}

extension SurfaceReading {
    /// What the gallery shows before the app has written anything: four accounts, every state
    /// the ring can draw.
    static let preview: SurfaceReading = {
        func account(_ index: Int, _ name: String, _ provider: AccountProvider, weekly: Int, session: Int, state: AccountLevel.State) -> SurfaceAccount {
            let id = AccountID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!)
            return SurfaceAccount(
                id: id, name: name, provider: provider, order: index - 1, needsSignIn: false,
                level: AccountLevel(weeklyRemainingPercent: weekly, sessionRemainingPercent: session, state: state, returnsAt: nil),
                windows: [], observedAt: Date(), planName: nil
            )
        }
        return SurfaceReading(
            accounts: [
                account(1, "Personal", .anthropic, weekly: 71, session: 53, state: .reading),
                account(2, "Work", .openai, weekly: 46, session: 46, state: .reading),
                account(3, "Research", .anthropic, weekly: 14, session: 14, state: .low),
                account(4, "Spare", .openai, weekly: 0, session: 0, state: .spent),
            ],
            namesHidden: false,
            stripShows: .session,
            readAt: Date()
        )
    }()
}
