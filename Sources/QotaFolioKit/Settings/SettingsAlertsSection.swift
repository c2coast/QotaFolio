import AppKit
import SwiftUI
import QotaFolioCore

/// Settings → Alerts: whether the app may say anything at all, which accounts it may say it
/// about, and where the person stands with the system on notifications from this app.
///
/// Every alert is a sentence in a banner and nothing more: no button, no action, nothing to
/// press. The person reads it or does not.
public struct SettingsAlertsSection: View {
    private let catalog: any AccountCataloging
    private let preferences: AlertPreferences
    private let alerts: AlertDeliverer

    public init(catalog: any AccountCataloging, preferences: AlertPreferences, alerts: AlertDeliverer) {
        self.catalog = catalog
        self.preferences = preferences
        self.alerts = alerts
    }

    public var body: some View {
        Form {
            Section {
                Toggle(
                    qfLocalized("settings.alerts.enabled", defaultValue: "Show alerts", comment: "Master switch for the app's notifications."),
                    isOn: preferences.enabledBinding()
                )
                .accessibilityIdentifier(SettingsAXIdentifiers.alertsEnabled)
            } header: {
                Text(qfLocalized("settings.alerts.section", defaultValue: "Alerts", comment: "Settings Alerts section title."))
            } footer: {
                Text(qfLocalized(
                    "settings.alerts.help",
                    defaultValue: "An alert is one sentence in a notification: an account running out before its reset, a window that has just reset, or part of a week that will expire unused. Nothing in it asks you to do anything.",
                    comment: "Explains what the app's alerts say and that they carry no actions."
                ))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !catalog.accounts.isEmpty {
                Section {
                    ForEach(catalog.accounts) { account in
                        Toggle(isOn: preferences.enabledBinding(for: account.id)) {
                            HStack(spacing: 10) {
                                ProviderMark(provider: account.provider)
                                    .frame(width: 18, height: 18)
                                Text(account.name)
                            }
                        }
                        .disabled(!preferences.isEnabled)
                        .accessibilityLabel(qfLocalized(
                            "settings.alerts.account.label",
                            defaultValue: "Alerts for \(account.name)",
                            comment: "VoiceOver label for one account's alerts switch. The argument is the account name."
                        ))
                    }
                } header: {
                    Text(qfLocalized("settings.alerts.accounts", defaultValue: "Accounts", comment: "Settings Alerts per-account section title."))
                }
            }

            Section {
                Label {
                    Text(permissionSentence)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: permissionSymbol)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(SettingsAXIdentifiers.alertsPermission)

                if alerts.authorization == .denied {
                    Button {
                        openNotificationSettings()
                    } label: {
                        Label(
                            qfLocalized("settings.alerts.openSystemSettings", defaultValue: "Open Notification settings…", comment: "Opens System Settings at the Notifications pane."),
                            systemImage: "gearshape"
                        )
                    }
                    .frame(minWidth: 40, minHeight: 40)
                }
            } header: {
                Text(qfLocalized("settings.alerts.permission", defaultValue: "Permission", comment: "Settings Alerts section about the system's notification permission."))
            }
        }
        .formStyle(.grouped)
        .task { await alerts.refreshAuthorization() }
    }

    private var permissionSentence: String {
        switch alerts.authorization {
        case .authorized:
            qfLocalized("settings.alerts.permission.on", defaultValue: "macOS allows notifications from QotaFolio.", comment: "Permission state: notifications are allowed.")
        case .denied:
            qfLocalized("settings.alerts.permission.off", defaultValue: "Notifications from QotaFolio are turned off. Turn them on in System Settings → Notifications → QotaFolio.", comment: "Permission state: notifications are denied, and where to turn them on.")
        case .notDetermined:
            qfLocalized("settings.alerts.permission.notAsked", defaultValue: "macOS will ask for permission the first time an alert is due.", comment: "Permission state: the system has not been asked yet.")
        case .unknown:
            qfLocalized("settings.alerts.permission.unknown", defaultValue: "QotaFolio could not read the notification permission.", comment: "Permission state: the system gave no readable answer.")
        }
    }

    private var permissionSymbol: String {
        switch alerts.authorization {
        case .authorized: "bell"
        case .denied: "bell.slash"
        case .notDetermined, .unknown: "bell.badge"
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
