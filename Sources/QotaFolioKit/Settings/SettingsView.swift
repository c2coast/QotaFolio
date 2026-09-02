import Observation
import SwiftUI
import QotaFolioCore

/// The Settings window's tabs, in the order they are shown.
public enum SettingsTab: String, CaseIterable, Sendable {
    case general, accounts, alerts, privacy, updates, about
}

public struct SettingsView: View {
    private let updater: any SettingsUpdating
    private let launchAtLogin: any LoginAtStartupControlling
    private let catalog: any AccountCataloging
    private let addFlow: any AddFlowPresenting
    private let visibility: any AccountVisibilityControlling
    private let uninstall: any UninstallPresenting
    private let alertPreferences: AlertPreferences
    private let alerts: AlertDeliverer
    private let privacy: ScreenPrivacy
    private let panelShortcut: GlobalShortcutStore
    private let appearance: AppearancePreferences
    private let stripShows: StripPreferences

    @State private var selectedTab: SettingsTab

    public init(
        updater: any SettingsUpdating,
        launchAtLogin: any LoginAtStartupControlling,
        catalog: any AccountCataloging,
        addFlow: any AddFlowPresenting,
        visibility: any AccountVisibilityControlling,
        uninstall: any UninstallPresenting,
        alertPreferences: AlertPreferences,
        alerts: AlertDeliverer,
        privacy: ScreenPrivacy,
        panelShortcut: GlobalShortcutStore,
        appearance: AppearancePreferences,
        stripShows: StripPreferences,
        initialTab: SettingsTab = .general
    ) {
        self.updater = updater
        self.launchAtLogin = launchAtLogin
        self.catalog = catalog
        self.addFlow = addFlow
        self.visibility = visibility
        self.uninstall = uninstall
        self.alertPreferences = alertPreferences
        self.alerts = alerts
        self.privacy = privacy
        self.panelShortcut = panelShortcut
        self.appearance = appearance
        self.stripShows = stripShows
        _selectedTab = State(initialValue: initialTab)
    }

    public var body: some View {
        // Both reads happen here, inside `body`, so the window re-renders the moment
        // the flow phase or the uninstall state changes.
        let presentsAddFlow = settingsPresentsAddFlow(
            addFlow.activeFlow,
            uninstallState: uninstall.state
        )

        TabView(selection: $selectedTab) {
            SettingsGeneralSection(
                launchAtLogin: launchAtLogin,
                uninstall: uninstall,
                panelShortcut: panelShortcut,
                appearance: appearance,
                stripShows: stripShows
            )
            .tabItem {
                Label(
                    qfLocalized("settings.tab.general", defaultValue: "General", comment: "General Settings tab."),
                    systemImage: "gearshape"
                )
            }
            .tag(SettingsTab.general)

            SettingsAccountsSection(
                catalog: catalog,
                addFlow: addFlow,
                visibility: visibility
            )
            .tabItem {
                Label(
                    qfLocalized("settings.tab.accounts", defaultValue: "Accounts", comment: "Accounts Settings tab."),
                    systemImage: "person.2"
                )
            }
            .tag(SettingsTab.accounts)

            SettingsAlertsSection(catalog: catalog, preferences: alertPreferences, alerts: alerts)
                .tabItem {
                    Label(
                        qfLocalized("settings.tab.alerts", defaultValue: "Alerts", comment: "Alerts Settings tab."),
                        systemImage: "bell"
                    )
                }
                .tag(SettingsTab.alerts)

            SettingsPrivacySection(privacy: privacy)
                .tabItem {
                    Label(
                        qfLocalized("settings.tab.privacy", defaultValue: "Privacy", comment: "Privacy Settings tab."),
                        systemImage: "hand.raised"
                    )
                }
                .tag(SettingsTab.privacy)

            SettingsUpdatesSection(updater: updater)
                .tabItem {
                    Label(
                        qfLocalized("settings.tab.updates", defaultValue: "Updates", comment: "Updates Settings tab."),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .tag(SettingsTab.updates)

            AboutView()
                .tabItem {
                    Label(
                        qfLocalized("settings.tab.about", defaultValue: "About", comment: "About Settings tab."),
                        systemImage: "info.circle"
                    )
                }
                .tag(SettingsTab.about)
        }
        .scenePadding()
        .frame(width: 700, height: 520)
        .sheet(isPresented: addFlowPresentation(presentsAddFlow)) {
            SettingsAddFlowSheet(addFlow: addFlow)
        }
        .onChange(of: presentsAddFlow) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            announceConnectedAccount()
        }
    }

    /// The sheet's own presentation state is the flow phase, so the binding reads
    /// the value already computed in `body`. SwiftUI writing `false` means the user
    /// dismissed the sheet, and a dismissed add flow is a cancelled add flow.
    private func addFlowPresentation(_ isPresented: Bool) -> Binding<Bool> {
        Binding(
            get: { isPresented },
            set: { [addFlow] presented in
                guard !presented else { return }
                addFlow.cancelActiveFlow(.userCancel)
            }
        )
    }

    /// Settings presented the flow, so Settings owes the success signal.
    ///
    /// The announcement is produced on every completed add and cleared by exactly
    /// one atomic consumer. Without this call the panel would announce it hours
    /// later, on its next appearance, for an account connected here.
    private func announceConnectedAccount() {
        guard let accountID = addFlow.consumeConnectedAnnouncement() else { return }

        let accountName = catalog.accounts.first(where: { $0.id == accountID })?.name
            ?? qfLocalized("account.generic", defaultValue: "Account", comment: "Generic account name used only if a connected row is not yet visible.")
        AccessibilityAnnouncer.layoutChanged()
        AccessibilityAnnouncer.announce(
            qfLocalized(
                "announce.connected",
                defaultValue: "\(accountName) connected",
                comment: "VoiceOver announcement after an account successfully connects."
            )
        )
    }
}
