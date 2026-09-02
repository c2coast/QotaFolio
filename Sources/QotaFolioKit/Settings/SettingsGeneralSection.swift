import SwiftUI
import QotaFolioCore

public struct SettingsGeneralSection: View {
    private let launchAtLogin: any LoginAtStartupControlling
    private let uninstall: any UninstallPresenting
    private let panelShortcut: GlobalShortcutStore
    private let appearance: AppearancePreferences
    private let stripShows: StripPreferences

    @State private var showsConfirmation = false
    @State private var copiedTerminalPath = false

    public init(
        launchAtLogin: any LoginAtStartupControlling,
        uninstall: any UninstallPresenting,
        panelShortcut: GlobalShortcutStore,
        appearance: AppearancePreferences,
        stripShows: StripPreferences
    ) {
        self.launchAtLogin = launchAtLogin
        self.uninstall = uninstall
        self.panelShortcut = panelShortcut
        self.appearance = appearance
        self.stripShows = stripShows
    }

    public var body: some View {
        Group {
            switch uninstall.state {
            case .removing:
                removingView
            case .finished(let problems):
                finishedView(problems)
            case .idle, .confirmation:
                generalForm
            }
        }
        .onAppear { launchAtLogin.refresh() }
        .onChange(of: launchAtLogin.externalStatusChangeCount) { _, _ in
            // The registration changed in System Settings, with nobody touching this
            // control. VoiceOver announces the reconciled state because the toggle
            // moved on its own.
            announceReconciledLoginStatus()
        }
        .onChange(of: uninstall.state) { _, state in
            switch state {
            case .confirmation:
                showsConfirmation = true
            case .idle, .removing, .finished:
                showsConfirmation = false
            }
        }
        .sheet(isPresented: $showsConfirmation, onDismiss: {
            uninstall.cancelConfirmation()
        }) {
            confirmationSheet
        }
    }

    private var generalForm: some View {
        Form {
            Section(
                qfLocalized("settings.general.startup", defaultValue: "Startup", comment: "Settings section for Launch at Login.")
            ) {
                Toggle(
                    qfLocalized("settings.general.launchAtLogin", defaultValue: "Open QotaFolio at login", comment: "Launch at Login preference."),
                    isOn: launchAtLogin.enabledBinding()
                )
                .accessibilityIdentifier(SettingsAXIdentifiers.launchAtLogin)

                if let failureMessage = launchAtLogin.failureMessage {
                    Text(failureMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("qotafolio.settings.launchAtLogin.failure")
                }

                if launchAtLogin.status == .requiresApproval {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(qfLocalized(
                            "settings.general.launchAtLogin.needsApproval",
                            defaultValue: "macOS needs your approval before QotaFolio can open at login.",
                            comment: "Launch at Login requires approval in System Settings."
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Button {
                            launchAtLogin.openLoginItemsSettings()
                        } label: {
                            Label(
                                qfLocalized("settings.general.openLoginItems", defaultValue: "Open Login Items settings…", comment: "Open the macOS Login Items settings pane."),
                                systemImage: "gearshape"
                            )
                        }
                        .frame(minWidth: 40, minHeight: 40)
                        .accessibilityIdentifier("qotafolio.settings.launchAtLogin.openLoginItems")
                    }
                }
            }

            Section(
                qfLocalized("settings.general.appearance", defaultValue: "Appearance", comment: "Settings section for the light/dark choice.")
            ) {
                Picker(
                    qfLocalized("settings.appearance.label", defaultValue: "QotaFolio's windows", comment: "The appearance picker's row label. The choice covers the panel and the Settings window."),
                    selection: appearance.binding()
                ) {
                    Text(qfLocalized("settings.appearance.system", defaultValue: "System", comment: "Appearance choice: follow the Mac.")).tag(QotaFolioAppearance.system)
                    Text(qfLocalized("settings.appearance.light", defaultValue: "Light", comment: "Appearance choice: always light.")).tag(QotaFolioAppearance.light)
                    Text(qfLocalized("settings.appearance.dark", defaultValue: "Dark", comment: "Appearance choice: always dark.")).tag(QotaFolioAppearance.dark)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(SettingsAXIdentifiers.appearance)

                Text(qfLocalized(
                    "settings.appearance.hint",
                    defaultValue: "The batteries stay with the menu bar, which has a light and a dark of its own.",
                    comment: "One line under the appearance picker, saying why the menu-bar batteries do not follow this choice."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(
                qfLocalized("settings.general.menuBar", defaultValue: "Menu bar", comment: "Settings section for what the menu-bar batteries are drawn to.")
            ) {
                Picker(
                    qfLocalized("settings.strip.label", defaultValue: "The menu-bar batteries", comment: "The row label for which quantity the menu-bar batteries are drawn to."),
                    selection: stripShows.binding()
                ) {
                    Text(qfLocalized("settings.strip.session", defaultValue: "This session", comment: "Battery quantity: what this five-hour session still holds.")).tag(StripShows.session)
                    Text(qfLocalized("settings.strip.week", defaultValue: "This week", comment: "Battery quantity: what the week still holds.")).tag(StripShows.week)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(SettingsAXIdentifiers.stripShows)

                Text(qfLocalized(
                    "settings.strip.hint",
                    defaultValue: "This session is what this five-hour session still holds; this week is what the week still holds. Each is drawn on its own; the words say both. The Control shows the same figure.",
                    comment: "One line under the menu-bar battery picker, naming both quantities, saying each is drawn on its own and that the Control follows the choice."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(
                qfLocalized("settings.general.shortcut", defaultValue: "Keyboard", comment: "Settings section for the global panel shortcut.")
            ) {
                LabeledContent(
                    qfLocalized("settings.shortcut.label", defaultValue: "Open the panel from anywhere", comment: "The panel shortcut's row label.")
                ) {
                    ShortcutRecorderView(store: panelShortcut)
                }
            }

            Section(
                qfLocalized("settings.general.terminal", defaultValue: "Terminal", comment: "Settings section for the qota command.")
            ) {
                LabeledContent(
                    qfLocalized("settings.terminal.label", defaultValue: "qota status", comment: "The terminal command's row label — the command itself.")
                ) {
                    HStack(spacing: 8) {
                        Text(Self.qotaPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Self.qotaPath, forType: .string)
                            copiedTerminalPath = true
                        } label: {
                            Text(copiedTerminalPath
                                ? qfLocalized("settings.terminal.copied", defaultValue: "Copied", comment: "Shown after the command's path was copied.")
                                : qfLocalized("settings.terminal.copy", defaultValue: "Copy", comment: "Copies the command's path."))
                        }
                        .accessibilityIdentifier("qotafolio.settings.terminal.copy")
                    }
                }
                Text(qfLocalized(
                    "settings.terminal.hint",
                    defaultValue: "Prints every account's current usage in Terminal. Add --json for scripts.",
                    comment: "One line under the terminal command's path."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section(
                qfLocalized("settings.general.data", defaultValue: "Data", comment: "Settings section for local QotaFolio data removal.")
            ) {
                Button(role: .destructive) {
                    uninstall.requestConfirmation()
                    showsConfirmation = true
                } label: {
                    Label(
                        qfLocalized("settings.uninstall.entry", defaultValue: "Remove My Data…", comment: "Open the data-removal confirmation."),
                        systemImage: "trash"
                    )
                }
                .frame(minWidth: 40, minHeight: 40)
                .accessibilityIdentifier(AXIdentifiers.settingsUninstall)
            }
        }
        .formStyle(.grouped)
    }

    /// Where the command ships: inside this very app.
    static var qotaPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/qota").path
    }

    private func announceReconciledLoginStatus() {
        let message = switch launchAtLogin.status {
        case .enabled:
            qfLocalized(
                "announce.launchAtLogin.enabled",
                defaultValue: "Open at login is on",
                comment: "VoiceOver announcement after the app reconciles an Open-at-Login approval made in System Settings."
            )
        case .disabled:
            qfLocalized(
                "announce.launchAtLogin.disabled",
                defaultValue: "Open at login is off",
                comment: "VoiceOver announcement after the app reconciles an Open-at-Login removal made in System Settings."
            )
        case .requiresApproval:
            qfLocalized(
                "announce.launchAtLogin.needsApproval",
                defaultValue: "Open at login needs your approval in System Settings",
                comment: "VoiceOver announcement after the app reconciles an Open-at-Login registration that is still waiting for approval."
            )
        }
        AccessibilityAnnouncer.announce(message)
    }

    /// The one screen that has to be exactly true.
    ///
    /// It says what goes, what stays, and what the user would have to do to come back —
    /// in those words, rather than in the word "irreversible", which tells nobody anything.
    @ViewBuilder private var confirmationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(qfLocalized("uninstall.confirmation.title", defaultValue: "Remove your QotaFolio data?", comment: "Data-removal confirmation title."))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text(qfLocalized(
                "uninstall.confirmation.body",
                defaultValue: "QotaFolio will delete the sign-ins it holds for your accounts, along with your account list, your settings and its update files. There is no way to get them back afterwards — to use QotaFolio again you would sign in to each account once more.\n\nYour Anthropic and ChatGPT accounts stay as they are: nothing is cancelled, and no other app is signed out. QotaFolio does end the permission it created for itself on your Anthropic account. ChatGPT offers no way to do that, so its permission stays until you remove it yourself.\n\nQotaFolio will quit when it is done, and you can then drag it to the Trash.",
                comment: "Exact scope of local data removal, and what it costs the user."
            ))
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    uninstall.cancelConfirmation()
                } label: {
                    Text(qfLocalized("action.cancel", defaultValue: "Cancel", comment: "Cancel an in-progress operation."))
                }
                .keyboardShortcut(.cancelAction)
                .frame(minWidth: 40, minHeight: 40)
                .accessibilityIdentifier(AXIdentifiers.uninstallCancel)

                Spacer()

                Button(role: .destructive) {
                    uninstall.confirmRemoval()
                } label: {
                    Text(qfLocalized("uninstall.confirm", defaultValue: "Remove My Data", comment: "Confirm local data removal."))
                }
                .keyboardShortcut(.defaultAction)
                .frame(minWidth: 40, minHeight: 40)
                .accessibilityIdentifier(AXIdentifiers.uninstallConfirm)
            }
        }
        .padding(24)
        .frame(width: 500)
        .accessibilityIdentifier(AXIdentifiers.uninstallConfirmation)
    }

    private var removingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(qfLocalized("uninstall.removing", defaultValue: "Removing your QotaFolio data…", comment: "Data-removal progress state."))
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AXIdentifiers.uninstallProgress)
        .onAppear {
            AccessibilityAnnouncer.announce(qfLocalized("uninstall.removing", defaultValue: "Removing your QotaFolio data…", comment: "Data-removal progress state."))
        }
    }

    /// What happened, then the one thing left for the user to do.
    private func finishedView(_ problems: [UninstallStep]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(qfLocalized(
                    "uninstall.success",
                    defaultValue: "Your QotaFolio data is removed. Drag QotaFolio to the Trash to finish removing the app.",
                    comment: "Shown after local data removal has run."
                ))
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: problems.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(problems.isEmpty ? Color.green : Color.orange)
            }

            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(qfLocalized(
                        "uninstall.problems",
                        defaultValue: "One part of the removal did not finish:",
                        comment: "Introduces the list of removal steps that did not complete."
                    ))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    ForEach(problems, id: \.self) { problem in
                        Label(problem.label, systemImage: "xmark.circle")
                            .font(.body)
                    }
                }
                .accessibilityIdentifier(AXIdentifiers.uninstallFailure)
            }

            HStack {
                Button {
                    uninstall.showApplicationInFinder()
                } label: {
                    Label(
                        qfLocalized("uninstall.showInFinder", defaultValue: "Show QotaFolio in Finder", comment: "Select this app bundle in Finder."),
                        systemImage: "folder"
                    )
                }
                .frame(minWidth: 40, minHeight: 40)
                .accessibilityIdentifier(AXIdentifiers.uninstallShowInFinder)

                Spacer()

                Button {
                    uninstall.quitAfterRemoval()
                } label: {
                    Label(
                        qfLocalized("uninstall.quit", defaultValue: "Quit QotaFolio", comment: "Quit the app after local data removal."),
                        systemImage: "power"
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .frame(minWidth: 40, minHeight: 40)
                .accessibilityIdentifier("qotafolio.uninstall.quit")
            }
        }
        .padding(24)
        .accessibilityIdentifier(AXIdentifiers.uninstallSuccess)
    }
}

private nonisolated extension UninstallStep {
    var label: String {
        switch self {
        case .pollingStopped:
            qfLocalized("uninstall.step.polling", defaultValue: "Stopping the quota checks", comment: "Removal step name.")
        case .credentialsDeleted:
            qfLocalized("uninstall.step.credentials", defaultValue: "Deleting your saved sign-ins", comment: "Removal step name.")
        case .localFilesRemoved:
            qfLocalized("uninstall.step.localFiles", defaultValue: "Removing QotaFolio's files and settings", comment: "Removal step name.")
        case .openAtLoginUnregistered:
            qfLocalized("uninstall.step.openAtLogin", defaultValue: "Removing the Open at Login registration", comment: "Removal step name.")
        }
    }
}
