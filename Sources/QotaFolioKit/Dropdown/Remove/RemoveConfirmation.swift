import SwiftUI
import QotaFolioCore

/// Confirming an account removal, inline in the panel's own window.
///
/// A SwiftUI `.sheet` is a second `NSWindow`. The panel's dismissal monitor classifies the click
/// on Remove and the click on Cancel inside one as clicks outside the panel, and tears the panel
/// down before either button completes its mouse-down/mouse-up pair.
public struct RemoveConfirmation: View {
    public let account: AccountConfig
    /// Why the last Remove did nothing. The prompt stays open on a refusal: closing it would
    /// report a removal that never happened.
    public let refusalReason: String?
    public let remove: () -> Void
    public let cancel: () -> Void

    public init(
        account: AccountConfig,
        refusalReason: String?,
        remove: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.account = account
        self.refusalReason = refusalReason
        self.remove = remove
        self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                qfLocalized(
                    "remove.heading",
                    defaultValue: "Remove \(account.name)?",
                    comment: "Remove-account confirmation title containing the display name."
                )
            )
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)

            Text(
                qfLocalized(
                    "remove.body",
                    defaultValue: "Its saved sign-in will be deleted from this Mac. Where the provider allows it, QotaFolio also ends the permission it created for itself. Your account is not touched and no other app is signed out.",
                    comment: "Remove-account confirmation scope."
                )
            )
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            AccountPromptCaption(
                refusalReason: refusalReason,
                blockedReason: nil,
                validationReason: nil
            )

            HStack {
                Spacer()
                Button(
                    qfLocalized("action.cancel", defaultValue: "Cancel", comment: "Cancel an in-progress operation."),
                    action: cancel
                )
                .keyboardShortcut(.cancelAction)
                .frame(minHeight: 40)
                .accessibilityIdentifier(AXIdentifiers.removeCancel)

                Button(
                    qfLocalized("action.remove", defaultValue: "Remove", comment: "Confirm destructive account removal."),
                    role: .destructive,
                    action: remove
                )
                .keyboardShortcut(.defaultAction)
                // Prominent because it is the default action, and red because it destroys
                // something. A destructive default button that wears the safe button's blue is a
                // button the user presses by reflex.
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .frame(minHeight: 40)
                // The sentence, on the element VoiceOver is still focused on after the press.
                // The refusal is announced once, at the moment of the press. This is how the user
                // hears it again — on the button itself — instead of having to go and find the
                // caption. A caption a VoiceOver user has to go looking for is half an answer.
                .help(refusalReason ?? "")
                .accessibilityHint(refusalReason ?? "")
                .accessibilityIdentifier(AXIdentifiers.removeConfirm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
