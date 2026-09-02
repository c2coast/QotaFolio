import SwiftUI
import QotaFolioCore

/// Renaming an account, inline in the panel's own window.
///
/// A SwiftUI `.sheet` is its own `NSWindow`, so the panel's dismissal monitor reads every
/// keystroke in the field as a click outside the panel and tears the panel down before the
/// character arrives. The name says prompt because the panel opens no second window.
public struct RenamePrompt: View {
    public let account: AccountConfig
    /// Why Save is dimmed, when the rename is refused for a reason outside this prompt.
    ///
    /// The prompt can be open when an uninstall attempt closes persistent writes. Dismissing it
    /// would look like the rename was applied, and leaving Save live would let the user press a
    /// button whose write is refused in silence, so the prompt stays, says why, and dims Save.
    public let blockedReason: String?
    /// Why the last Save did nothing. The prompt stays open on a refusal: it is the one surface
    /// that can still say why, and closing it would report a rename that never happened.
    public let refusalReason: String?
    public let save: (String) -> Void
    public let cancel: () -> Void

    @State private var name: String
    @FocusState private var nameFocused: Bool

    public init(
        account: AccountConfig,
        blockedReason: String?,
        refusalReason: String?,
        save: @escaping (String) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.account = account
        self.blockedReason = blockedReason
        self.refusalReason = refusalReason
        self.save = save
        self.cancel = cancel
        self._name = State(initialValue: account.name)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(qfLocalized("rename.heading", defaultValue: "Rename account", comment: "Rename-account sheet title."))
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            TextField(
                qfLocalized("rename.field", defaultValue: "Account name", comment: "Account display-name field label."),
                text: $name
            )
            .textFieldStyle(.roundedBorder)
            .focused($nameFocused)
            .accessibilityIdentifier(AXIdentifiers.renameField)

            AccountPromptCaption(
                refusalReason: refusalReason,
                blockedReason: blockedReason,
                validationReason: trimmedName.isEmpty
                    ? qfLocalized("rename.empty", defaultValue: "Enter an account name.", comment: "Inline validation for an empty account name.")
                    : nil
            )

            HStack {
                Spacer()
                Button(
                    qfLocalized("action.cancel", defaultValue: "Cancel", comment: "Cancel an in-progress operation."),
                    action: cancel
                )
                .keyboardShortcut(.cancelAction)
                .frame(minHeight: 40)
                .accessibilityIdentifier(AXIdentifiers.renameCancel)

                Button(
                    qfLocalized("action.save", defaultValue: "Save", comment: "Save an edited account name."),
                    action: { save(trimmedName) }
                )
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .frame(minHeight: 40)
                .disabled(trimmedName.isEmpty || blockedReason != nil)
                // A refused press outranks a closed admission here, the way it does on the card's
                // Reconnect: both can be true at once, and the refusal is the newer fact and the
                // one the user just asked for. The sentence sits on the element VoiceOver is
                // still focused on after the press, so the answer announced at the press can be
                // heard again without going looking for the caption.
                .help(refusalReason ?? blockedReason ?? "")
                .accessibilityHint(refusalReason ?? blockedReason ?? "")
                .accessibilityIdentifier(AXIdentifiers.renameSave)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { nameFocused = true }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
