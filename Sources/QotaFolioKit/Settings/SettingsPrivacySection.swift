import SwiftUI
import QotaFolioCore

/// Settings → Privacy: the blanket, and one sentence about what leaves this Mac.
public struct SettingsPrivacySection: View {
    private let privacy: ScreenPrivacy

    public init(privacy: ScreenPrivacy) {
        self.privacy = privacy
    }

    public var body: some View {
        Form {
            Section {
                Toggle(
                    qfLocalized("settings.privacy.hideNames", defaultValue: "Hide account names", comment: "Switch that hides account names on the panel and in the strip's words."),
                    isOn: privacy.hideNamesBinding()
                )
                .accessibilityIdentifier(SettingsAXIdentifiers.privacyHideNames)

                if privacy.automaticFormIsAvailable {
                    Toggle(
                        qfLocalized("settings.privacy.hideNamesWhileShared", defaultValue: "Hide them while the screen is shared", comment: "Switch for the automatic blanket: names hidden and batteries colourless while the screen is shared or recorded."),
                        isOn: privacy.hidesNamesWhileSharedBinding()
                    )
                    .accessibilityIdentifier(SettingsAXIdentifiers.privacyHideNamesWhileShared)
                }

                Label {
                    Text(blanketSentence)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: privacy.screenIsWatched ? "rectangle.inset.filled.and.person.filled" : "rectangle.on.rectangle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(SettingsAXIdentifiers.privacyBlanket)
            } header: {
                Text(qfLocalized("settings.privacy.section", defaultValue: "Screen sharing", comment: "Settings Privacy section title about screen sharing."))
            } footer: {
                Text(qfLocalized(
                    "settings.privacy.hideNames.help",
                    defaultValue: "With names hidden, each account is called by its provider — “Anthropic account”, “ChatGPT account” — and the batteries are drawn without colour.",
                    comment: "Explains what hiding names changes on the panel and in the strip."
                ))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Text(qfLocalized(
                    "settings.privacy.leaves",
                    defaultValue: "QotaFolio sends nothing anywhere except its own requests to Anthropic and OpenAI for your usage, made with your sign-in. No analytics, no telemetry, no third parties.",
                    comment: "One sentence on what leaves the Mac: only the provider requests."
                ))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(SettingsAXIdentifiers.privacyLeaves)
            } header: {
                Text(qfLocalized("settings.privacy.leaves.section", defaultValue: "What leaves this Mac", comment: "Settings Privacy section title about data leaving the Mac."))
            }
        }
        .formStyle(.grouped)
    }

    private var blanketSentence: String {
        if privacy.screenIsWatched, privacy.hidesNamesWhileShared {
            return qfLocalized(
                "settings.privacy.blanket.on",
                defaultValue: "Your screen is being shared right now. Names are hidden and the batteries colourless until it ends.",
                comment: "Privacy state while a screen share or recording is in progress."
            )
        }
        if privacy.screenIsWatched {
            return qfLocalized(
                "settings.privacy.blanket.watchedButOff",
                defaultValue: "Your screen is being shared right now. Names stay on, as you chose.",
                comment: "Privacy state while the screen is shared and the automatic blanket is switched off."
            )
        }
        if privacy.automaticFormIsAvailable, !privacy.hidesNamesWhileShared {
            return qfLocalized(
                "settings.privacy.blanket.off",
                defaultValue: "QotaFolio will not hide names by itself. Use Hide account names when you share your screen.",
                comment: "Privacy state when the automatic blanket is switched off."
            )
        }
        if privacy.automaticFormIsAvailable {
            return qfLocalized(
                "settings.privacy.blanket.automatic",
                defaultValue: "While your screen is shared or recorded, QotaFolio hides names and colours by itself, and brings them back when it ends.",
                comment: "Privacy state when this Mac reports screen sharing to the app."
            )
        }
        return qfLocalized(
            "settings.privacy.blanket.manual",
            defaultValue: "This Mac does not tell apps when the screen is shared. Turn on Hide account names before you share your screen.",
            comment: "Privacy state when this Mac cannot report screen sharing to the app."
        )
    }
}
