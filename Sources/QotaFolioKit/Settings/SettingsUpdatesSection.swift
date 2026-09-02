import SwiftUI
import QotaFolioCore

public struct SettingsUpdatesSection: View {
    private let updater: any SettingsUpdating

    public init(updater: any SettingsUpdating) {
        self.updater = updater
    }

    public var body: some View {
        Form {
            switch updater.updateCheckAvailability {
            case .unavailable:
                Section { SettingsUpdatesUnavailableNotice() }
            case .busy, .ready:
                controls
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var controls: some View {
        Section {
            Toggle(
                qfLocalized("settings.updates.checkAutomatically", defaultValue: "Automatically check for updates", comment: "Sparkle automatic update-check preference."),
                isOn: updater.checksBinding()
            )

            Toggle(
                qfLocalized("settings.updates.downloadAutomatically", defaultValue: "Automatically download and install updates", comment: "Sparkle automatic update-download preference."),
                isOn: updater.downloadsBinding()
            )
            .disabled(!updater.automaticallyChecksForUpdates)
        }

        Section {
            Button {
                updater.checkForUpdates()
            } label: {
                Label(
                    qfLocalized("settings.updates.checkNow", defaultValue: "Check for Updates…", comment: "Manually check for a QotaFolio update."),
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            .disabled(updater.updateCheckAvailability != .ready)
            .frame(minWidth: 40, minHeight: 40)
            .accessibilityIdentifier("qotafolio.settings.updates.checkNow")
        }
    }
}

/// The one sentence shown when the updater is not running.
///
/// It *replaces* the update controls rather than sitting above them. A live toggle over an
/// updater that never started is a worse lie than an absent toggle: it invites the user to
/// configure something that cannot happen, and it keeps a Check button on screen whose only
/// effect is to reproduce the failure.
///
/// The sentence does not name the fault. Every failure that reaches here is a fault in the
/// bundle we shipped — a public key that is not 32 bytes of base64, a missing XPC service, a
/// bundle with no identifier or version — and none of them is anything the reader did or can
/// repair. What they can do is get a copy that works, so that is what the sentence says. The
/// fault itself goes to the unified log as a machine code.
struct SettingsUpdatesUnavailableNotice: View {
    var body: some View {
        Label(
            qfLocalized(
                "settings.updates.unavailable",
                defaultValue: "This copy of QotaFolio cannot update itself. Download the app again to get future versions.",
                comment: "Shown in place of the update controls when the updater could not start."
            ),
            systemImage: "exclamationmark.triangle"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("qotafolio.settings.updates.unavailable")
    }
}
