import SwiftUI
import QotaFolioCore

/// Why a visibility change was refused.
///
/// One case, because there is one rule. The type exists so that a refusal is a value the caller
/// has to read: answered with a bare `return`, the switch bound to the rule reads the unchanged
/// value back and animates itself on again, so the user sees a rejection they cannot read.
public nonisolated enum AccountVisibilityRefusal: Equatable, Sendable {
    /// Hiding this account would leave the panel and the status strip with nothing to show.
    case lastVisibleAccount
}

/// The sentence a user reads when a visibility change is refused.
///
/// One sentence, one call site. It is the tooltip on the dimmed switch and the hint VoiceOver
/// speaks, so a user who reaches the control by pointer or by keyboard is told the same thing.
public nonisolated func accountVisibilityRefusalReason(
    _ refusal: AccountVisibilityRefusal
) -> String {
    switch refusal {
    case .lastVisibleAccount:
        qfLocalized(
            "settings.accounts.visibility.lastVisible",
            defaultValue: "This is the only visible account. Show another account first, then hide this one.",
            comment: "Why the last visible account cannot be hidden."
        )
    }
}

/// The one place the rule "one account always stays visible" is decided.
///
/// Settings asks before it draws, so the switch on the last visible account arrives dimmed and
/// carrying its reason and the user never meets a bounce-back. The visibility controller asks
/// again before it writes, so a caller that drew no switch is refused the same way and told why.
public nonisolated func accountVisibilityRefusal(
    hiding accountID: AccountID,
    visibleAccountIDs: Set<AccountID>
) -> AccountVisibilityRefusal? {
    // An account that is already hidden has nothing to refuse: hiding it changes nothing.
    guard visibleAccountIDs.contains(accountID) else { return nil }
    return visibleAccountIDs.count > 1 ? nil : .lastVisibleAccount
}

public struct SettingsAccountsSection: View {
    private let catalog: any AccountCataloging
    private let addFlow: any AddFlowPresenting
    private let visibility: any AccountVisibilityControlling

    /// The account a rename is being typed for, and the name so far.
    @State private var renaming: AccountConfig?
    @State private var renameDraft = ""
    /// The account a removal is being confirmed for.
    @State private var removing: AccountConfig?
    /// Why the last rename, sign-in or removal did nothing, drawn under the rows.
    @State private var refusal: String?

    public init(
        catalog: any AccountCataloging,
        addFlow: any AddFlowPresenting,
        visibility: any AccountVisibilityControlling
    ) {
        self.catalog = catalog
        self.addFlow = addFlow
        self.visibility = visibility
    }

    public var body: some View {
        Form {
            Section {
                if catalog.accounts.isEmpty {
                    Text(qfLocalized("settings.accounts.empty", defaultValue: "No accounts are configured.", comment: "Settings Accounts tab empty state."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(catalog.accounts.enumerated()), id: \.element.id) { index, account in
                        accountRow(account, index: index)
                    }
                }
            } header: {
                Text(qfLocalized("settings.accounts.section", defaultValue: "Accounts", comment: "Settings Accounts section title."))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let refusal {
                        Label(refusal, systemImage: "exclamationmark.triangle.fill")
                            .accessibilityIdentifier(AXIdentifiers.authError)
                    }
                    Text(qfLocalized(
                        "settings.accounts.order.help",
                        defaultValue: "This order is the panel's and the menu bar's.",
                        comment: "Explains that the order in Settings is the order everywhere."
                    ))
                    Text(qfLocalized(
                        "settings.accounts.visibility.help",
                        defaultValue: "Hidden accounts remain connected but do not appear in the panel or status-strip election.",
                        comment: "Explains the account visibility preference boundary."
                    ))
                    Text(qfLocalized(
                        "settings.accounts.visibility.alwaysOne",
                        defaultValue: "One account always stays visible.",
                        comment: "States the rule that the last visible account cannot be hidden."
                    ))
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Button {
                    addFlow.beginAddFlow()
                } label: {
                    Label(
                        qfLocalized("footer.addAccount", defaultValue: "Add Account…", comment: "Button that opens the add-account flow, in the panel footer and in Settings."),
                        systemImage: "plus"
                    )
                }
                .frame(minWidth: 40, minHeight: 40)
                .disabled(addBlocked)
                .accessibilityIdentifier(AXIdentifiers.settingsAccountsAdd)
            }
        }
        .formStyle(.grouped)
        .alert(
            qfLocalized("settings.accounts.rename.title", defaultValue: "Rename Account", comment: "Title of the rename dialog in Settings."),
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { account in
            TextField(
                qfLocalized("auth.name.label", defaultValue: "Account name", comment: "Display-name field in the add-account flow."),
                text: $renameDraft
            )
            Button(qfLocalized("action.save", defaultValue: "Save", comment: "Save an edited account name.")) {
                rename(account, to: renameDraft)
            }
            Button(qfLocalized("action.cancel", defaultValue: "Cancel", comment: "Cancel an in-progress operation."), role: .cancel) {}
        } message: { account in
            Text(qfLocalized(
                "settings.accounts.rename.message",
                defaultValue: "Your name for this \(providerName(account.provider)) account, as the panel and the menu bar say it.",
                comment: "Body of the rename dialog in Settings. The argument is the provider's name."
            ))
        }
        .confirmationDialog(
            qfLocalized("settings.accounts.remove.title", defaultValue: "Remove this account?", comment: "Title of the removal confirmation in Settings."),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible,
            presenting: removing
        ) { account in
            Button(qfLocalized("action.removeAccount", defaultValue: "Remove Account", comment: "Remove one connected account and its saved sign-in."), role: .destructive) {
                remove(account)
            }
            Button(qfLocalized("action.cancel", defaultValue: "Cancel", comment: "Cancel an in-progress operation."), role: .cancel) {}
        } message: { account in
            Text(qfLocalized(
                "settings.accounts.remove.message",
                defaultValue: "\(account.name) leaves QotaFolio and its saved sign-in is deleted from this Mac. Nothing changes at the provider except that this sign-in ends.",
                comment: "Body of the removal confirmation in Settings. The argument is the account name."
            ))
        }
    }

    private func accountRow(_ account: AccountConfig, index: Int) -> some View {
        let hideRefusal = accountVisibilityRefusal(
            hiding: account.id,
            visibleAccountIDs: visibleAccountIDs
        )

        return HStack(spacing: 12) {
            ProviderMark(provider: account.provider)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.body.weight(.semibold))
                Text(providerName(account.provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button(qfLocalized("action.rename", defaultValue: "Rename…", comment: "Rename an account.")) {
                    renameDraft = account.name
                    renaming = account
                }
                Button(qfLocalized("action.reconnect", defaultValue: "Reconnect…", comment: "Reconnect an account with the provider.")) {
                    reconnect(account)
                }
                .disabled(renderableFlow(addFlow.activeFlow) != nil)
                Divider()
                Button(qfLocalized("action.removeAccount", defaultValue: "Remove Account", comment: "Remove one connected account and its saved sign-in."), role: .destructive) {
                    removing = account
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(minWidth: 40, minHeight: 40)
            .disabled(catalog.loadState == .unreadable)
            .help(qfLocalized("settings.accounts.actions", defaultValue: "Rename, reconnect, remove", comment: "Tooltip for an account row's actions menu in Settings."))
            .accessibilityLabel(qfLocalized(
                "action.more.forAccount",
                defaultValue: "More actions for \(account.name)",
                comment: "VoiceOver label for one account row's actions menu. The placeholder is the account's name."
            ))
            .accessibilityIdentifier(SettingsAXIdentifiers.accountActions(account.id))

            Toggle(
                qfLocalized("settings.accounts.show", defaultValue: "Show", comment: "Show an account in the panel and status strip."),
                isOn: visibility.visibilityBinding(for: account.id)
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(hideRefusal != nil)
            .help(hideRefusal.map(accountVisibilityRefusalReason) ?? "")
            .accessibilityLabel(qfLocalized("settings.accounts.show.label", defaultValue: "Show account", comment: "VoiceOver label for showing an account in the panel and status strip."))
            .accessibilityHint(hideRefusal.map(accountVisibilityRefusalReason) ?? "")

            Button {
                move(account, from: index, toGap: index - 1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .frame(minWidth: 40, minHeight: 40)
            .disabled(index == 0 || catalog.loadState == .unreadable)
            .help(qfLocalized("action.moveUp", defaultValue: "Move Up", comment: "Move an account earlier in display order."))

            Button {
                move(account, from: index, toGap: index + 2)
            } label: {
                Image(systemName: "arrow.down")
            }
            .frame(minWidth: 40, minHeight: 40)
            .disabled(index == catalog.accounts.count - 1 || catalog.loadState == .unreadable)
            .help(qfLocalized("action.moveDown", defaultValue: "Move Down", comment: "Move an account later in display order."))
        }
    }

    /// Reading this inside `body` is what makes the switches redraw the moment the count of
    /// visible accounts changes — hiding the second-to-last one dims the last one immediately.
    private var visibleAccountIDs: Set<AccountID> {
        Set(catalog.accounts.map(\.id).filter { visibility.isVisible($0) })
    }

    private var addBlocked: Bool {
        renderableFlow(addFlow.activeFlow) != nil
            || occupancy(
                accountCount: catalog.accounts.count,
                pendingReservationCount: catalog.pendingReservationCount
            ) >= qotaFolioMaximumAccounts
            || catalog.loadState == .unreadable
    }

    private func providerName(_ provider: AccountProvider) -> String {
        provider == .anthropic
            ? qfLocalized("provider.anthropic", defaultValue: "Anthropic", comment: "Anthropic provider name.")
            : qfLocalized("provider.openai", defaultValue: "ChatGPT", comment: "ChatGPT provider name.")
    }

    /// Renames, then reads the catalog back: a rename the catalog declined is said, not assumed.
    private func rename(_ account: AccountConfig, to name: String) {
        let requested = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty, requested != account.name else { return }
        catalog.rename(account.id, to: requested)
        let applied = catalog.accounts.contains { $0.id == account.id && $0.name == requested }
        refusal = applied ? nil : accountRenameRefusalReason(
            catalog.loadState == .unreadable ? .accountListUnreadable : .renameWasNotApplied
        )
        if applied {
            AccessibilityAnnouncer.announce(qfLocalized(
                "announce.renamed",
                defaultValue: "Renamed to \(requested)",
                comment: "VoiceOver announcement after an account is renamed. The argument is the new name."
            ))
        } else if let refusal {
            AccessibilityAnnouncer.announce(refusal)
        }
    }

    private func reconnect(_ account: AccountConfig) {
        refusal = addFlow.beginReauth(account.id).map(accountReconnectRefusalReason)
        if let refusal { AccessibilityAnnouncer.announce(refusal) }
    }

    private func remove(_ account: AccountConfig) {
        refusal = addFlow.removeAccount(account.id).map(accountRemovalRefusalReason)
        if let refusal { AccessibilityAnnouncer.announce(refusal) }
    }

    private func move(_ account: AccountConfig, from index: Int, toGap gap: Int) {
        let current = catalog.accounts.map(\.id)
        let next = reorderedIDs(current, moving: account.id, toGap: gap)
        guard next != current else { return }

        catalog.reorder(next)

        AccessibilityAnnouncer.announce(
            qfLocalized(
                "announce.moved",
                defaultValue: "Moved \(account.name) to position \((next.firstIndex(of: account.id) ?? index) + 1) of \(next.count)",
                comment: "VoiceOver announcement after account reorder."
            )
        )
    }

}
