import SwiftUI
import QotaFolioCore

/// Why the naming step is back on screen, in the words a user reads and VoiceOver speaks.
public nonisolated func addFlowRefusalReason(_ refusal: AddFlowRefusal) -> String {
    switch refusal {
    case .accountLimitReached:
        qfLocalized(
            "auth.add.refused.limit",
            defaultValue: "QotaFolio holds five accounts. Remove one before you add another.",
            comment: "Shown on the add-account naming step when the five-account maximum refused the new account."
        )
    case .accountChangesAreClosed:
        qfLocalized(
            "auth.add.refused.finishingQuit",
            defaultValue: "This account was not added. QotaFolio is finishing quitting, and nothing is being deleted.",
            comment: "Shown on the add-account naming step when a quit holds account changes closed. Nothing is being deleted."
        )
    case .accountListUnreadable:
        qfLocalized(
            "auth.add.refused.unreadable",
            defaultValue: "QotaFolio cannot read your account list right now. This account was not added.",
            comment: "Shown on the add-account naming step when the account list could not be read."
        )
    case .accountCouldNotBeReserved:
        qfLocalized(
            "auth.add.refused.notReserved",
            defaultValue: "QotaFolio could not start adding this account. Press Continue again in a moment.",
            comment: "Shown on the add-account naming step when reserving a place for the new account failed for an unexpected reason."
        )
    }
}

/// Records the answer a Continue on the naming step produced, and says it out loud.
///
/// The caption the step draws comes from `AddFlowPresenting.addFlowRefusal`, which the presenter
/// set as it answered. This is the announcement, and it is made from the answer to THIS press.
/// Reading the observable back instead would announce whatever happens to be in it — including a
/// refusal an earlier press left behind on a path that returns before the observable is cleared.
/// One press, one announcement, never zero and never stale.
///
/// A refused Continue leaves the naming step exactly where it was, with the typed name still in
/// the field and VoiceOver still on the button. So the sentence is spoken and the button carries
/// it as its hint; focus is not moved. The only place to move it to is the caption, which is not
/// a control, and a user who is put down somewhere they did not ask to be has to find their way
/// back before they can press anything at all.
@MainActor public func recordAddSubmissionAnswer(_ refusal: AddFlowRefusal?) {
    guard let refusal else { return }
    AccessibilityAnnouncer.announce(addFlowRefusalReason(refusal))
}

public struct NameProviderStep: View {
    @Binding public var name: String
    @Binding public var provider: AccountProvider
    /// Why the last Continue did not start a flow, or nil.
    ///
    /// The five-account cap unpicks the chosen provider and puts this step back on screen, so
    /// without a reason a user who pressed Continue watches their own form return with nothing
    /// said and no next step to take.
    public let refusalReason: String?
    public let continueAction: () -> Void
    public let cancel: () -> Void

    @FocusState private var nameFocused: Bool

    public init(
        name: Binding<String>,
        provider: Binding<AccountProvider>,
        refusalReason: String?,
        continueAction: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self._name = name
        self._provider = provider
        self.refusalReason = refusalReason
        self.continueAction = continueAction
        self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(qfLocalized("auth.add.heading", defaultValue: "Add an account", comment: "Heading for the add-account naming step."))
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AXIdentifiers.authHeading)

            TextField(
                qfLocalized("auth.name.label", defaultValue: "Account name", comment: "Display-name field in the add-account flow."),
                text: $name,
                prompt: Text(qfLocalized("auth.name.placeholder", defaultValue: "For example, Personal or Work", comment: "Account display-name example."))
            )
            .textFieldStyle(.roundedBorder)
            .focused($nameFocused)
            .accessibilityIdentifier(AXIdentifiers.authNameField)

            Picker(
                qfLocalized("auth.provider.label", defaultValue: "Provider", comment: "Provider picker label in the add-account flow."),
                selection: $provider
            ) {
                providerChoice(
                    .anthropic,
                    qfLocalized("provider.anthropic", defaultValue: "Anthropic", comment: "Anthropic provider name.")
                )
                .tag(AccountProvider.anthropic)
                providerChoice(
                    .openai,
                    qfLocalized("provider.openai", defaultValue: "ChatGPT", comment: "ChatGPT provider name.")
                )
                .tag(AccountProvider.openai)
            }
            .pickerStyle(.radioGroup)
            .accessibilityIdentifier(AXIdentifiers.authProvider)

            PreConnectDisclosure()

            // The slot is always here, whether or not it has anything to say: a caption that
            // appeared out of nothing would move the button under it and grow the glass around it,
            // for a sentence the person has already read.
            Label(refusalReason ?? " ", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(refusalReason == nil ? 0 : 1)
                .accessibilityHidden(refusalReason == nil)
                .accessibilityIdentifier(AXIdentifiers.authError)

            HStack {
                Button(
                    qfLocalized("action.cancel", defaultValue: "Cancel", comment: "Cancel an in-progress operation."),
                    action: cancel
                )
                .keyboardShortcut(.cancelAction)
                .frame(minWidth: 40, minHeight: 40)
                .accessibilityIdentifier(AXIdentifiers.authCancel)

                Spacer()

                Button(
                    qfLocalized("action.continue", defaultValue: "Continue", comment: "Continue to provider sign-in."),
                    action: continueAction
                )
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 40, minHeight: 40)
                .disabled(trimmedName.isEmpty)
                // The sentence, on the element VoiceOver is still focused on after the press.
                // The announcement is heard once, at the moment of the press; this is how the
                // user hears it again without going looking for the caption.
                .help(refusalReason ?? "")
                .accessibilityHint(refusalReason ?? "")
                .accessibilityIdentifier(AXIdentifiers.authContinue)
            }
        }
        .onAppear { nameFocused = true }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The provider's own mark beside its name, the way the cards carry it.
    private func providerChoice(_ provider: AccountProvider, _ name: String) -> some View {
        HStack(spacing: 8) {
            ProviderMark(provider: provider)
                .frame(width: 18, height: 18)
            Text(name)
        }
        .frame(minHeight: 24)
    }
}
