import SwiftUI
import QotaFolioCore

public struct AuthProgressStep: View {
    public let phase: AccountFlowPhase
    public let provider: AccountProvider
    public let cancel: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        phase: AccountFlowPhase,
        provider: AccountProvider,
        cancel: (() -> Void)?
    ) {
        self.phase = phase
        self.provider = provider
        self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(
                qfLocalized(
                    "auth.heading.signIn",
                    defaultValue: "Sign in to \(providerName)",
                    comment: "Heading for a provider sign-in flow after provider selection."
                )
            )
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(AXIdentifiers.authHeading)

            HStack(spacing: 12) {
                if reduceMotion {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(Color.accentColor)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(progressText)
                    .font(.body)
            }
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)

            if let cancel {
                Button(
                    qfLocalized("action.cancel", defaultValue: "Cancel", comment: "Cancel an in-progress operation."),
                    action: cancel
                )
                .keyboardShortcut(.cancelAction)
                .frame(minWidth: 40, minHeight: 40)
                .accessibilityIdentifier(AXIdentifiers.authCancel)
            }
        }
    }

    private var providerName: String {
        provider == .anthropic
            ? qfLocalized("provider.anthropic", defaultValue: "Anthropic", comment: "Anthropic provider name.")
            : qfLocalized("provider.openai", defaultValue: "ChatGPT", comment: "ChatGPT provider name.")
    }

    private var progressText: String {
        switch phase {
        case .starting:
            qfLocalized("auth.progress.starting", defaultValue: "Starting sign-in…", comment: "Provider sign-in is starting.")
        case .exchanging:
            qfLocalized("auth.progress.exchanging", defaultValue: "Finishing sign-in…", comment: "Provider code is being exchanged for credentials.")
        case .storing:
            qfLocalized("auth.progress.storing", defaultValue: "Saving sign-in…", comment: "Credential is being saved to the Mac Keychain.")
        case .naming, .anthropicWaitingInBrowser, .openAIAwaitingDevice, .connected, .failed:
            qfLocalized("auth.progress.starting", defaultValue: "Starting sign-in…", comment: "Provider sign-in is starting.")
        }
    }
}
