import AppIntents
import QotaFolioModel
import SwiftUI
import WidgetKit

/// Which account a Control shows. Optional, so the gallery can preview the control before a
/// person has chosen; the provider then shows the first account.
// Not `nonisolated` on the type: `@Parameter` is a mutable stored property and the modifier
// cannot apply to it. `AppIntent` itself requires Sendable, so the conformance carries it.
struct SelectQuotaAccountIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Account"
    static let description = IntentDescription("Which account this control shows.")

    @Parameter(title: "Account")
    var account: QuotaAccountEntity?

    init() {}

    init(account: QuotaAccountEntity?) {
        self.account = account
    }
}

/// What the Control draws: the battery symbol at the account's level and the title that says
/// the numbers.
nonisolated struct AccountControlValue: Sendable {
    let title: String
    let symbolName: String
    let hasAccount: Bool
}

nonisolated struct AccountControlValueProvider: AppIntentControlValueProvider {
    func previewValue(configuration: SelectQuotaAccountIntent) -> AccountControlValue {
        let reading = SurfaceReading.preview
        let account = reading.accounts[0]
        return AccountControlValue(
            title: controlTitle(for: account, namesHidden: false),
            symbolName: batterySymbolName(for: account.level, showing: reading.stripShows),
            hasAccount: true
        )
    }

    func currentValue(configuration: SelectQuotaAccountIntent) async throws -> AccountControlValue {
        guard case .reading(let reading) = SurfaceReading.read(), !reading.accounts.isEmpty else {
            return AccountControlValue(
                title: String(localized: "No accounts yet", comment: "Control title when the app has no accounts."),
                symbolName: batterySymbolName(for: .noReading(.unavailable), showing: .session),
                hasAccount: false
            )
        }
        let account = configuration.account.flatMap { reading.account($0.id) } ?? reading.accounts[0]
        return AccountControlValue(
            title: controlTitle(for: account, namesHidden: reading.namesHidden),
            symbolName: batterySymbolName(for: account.level, showing: reading.stripShows),
            hasAccount: true
        )
    }
}

/// One account's battery in the menu bar or Control Center. Clicking it opens the panel.
struct AccountControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: SurfaceKind.accountControl,
            provider: AccountControlValueProvider()
        ) { value in
            ControlWidgetButton(action: OpenQotaFolioIntent(target: .panel)) {
                Label(value.title, image: value.symbolName)
            }
        }
        .promptsForUserConfiguration()
        .displayName("QotaFolio Account")
        // A literal, because `ControlWidgetConfiguration.description` takes only a
        // `LocalizedStringResource` and a literal is one.
        .description("One account's battery, drawn to the same quantity as the ones on the menu bar.")
    }
}

/// "Personal · 53% now · 71% this week" — the title carries the numbers, because a control
/// button has a title and a symbol and nothing else.
nonisolated func controlTitle(for account: SurfaceAccount, namesHidden: Bool) -> String {
    "\(presentedName(for: account, namesHidden: namesHidden)) · \(levelSentence(for: account.level))"
}

/// The custom symbol for a level: Apple's battery outline filled to the quantity the person has
/// the batteries drawn to, in five-point steps; the hairline when there is none of it; the empty
/// outline for no reading. One window's own share, exactly as the strip draws it.
///
/// The same projection the menu-bar battery is drawn from, so the battery on the bar and the
/// battery in Control Center are one length apart from their size. The twenty-three symbols are
/// figure-agnostic: they carry a fill, not a meaning.
nonisolated func batterySymbolName(for level: AccountLevel, showing: StripShows) -> String {
    guard level.hasReading else { return "qf.battery.empty" }
    let figure = StripFigure(
        showing: showing,
        weeklyRemainingPercent: level.weeklyRemainingPercent,
        sessionRemainingPercent: level.sessionRemainingPercent
    )
    if figure.isSpent { return "qf.battery.spent" }
    let step = Int((Double(figure.remainingPercent) / 5).rounded()) * 5
    return "qf.battery.\(min(100, max(0, step)))"
}
