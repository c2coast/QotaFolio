import SwiftUI
import QotaFolioCore

public struct AnthropicBrowserStep: View {
    public let authorizationURL: URL
    public let reopen: () -> Void
    public let cancel: () -> Void

    public init(
        authorizationURL: URL,
        reopen: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.authorizationURL = authorizationURL
        self.reopen = reopen
        self.cancel = cancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(qfLocalized(
                    "auth.anthropic.waiting",
                    defaultValue: "Waiting for \(authorizationURL.host() ?? "claude.ai") to confirm…",
                    comment: "Anthropic browser OAuth wait state. Only the host is shown."
                ))
                .font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: "safari")
                    .foregroundStyle(Color.accentColor)
            }
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(AXIdentifiers.anthropicStatus)

            Text(qfLocalized(
                "auth.anthropic.body",
                defaultValue: "Finish signing in in your browser. You can reopen the same authorization page without restarting this sign-in.",
                comment: "Anthropic loopback OAuth instructions."
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(
                    qfLocalized("action.cancel", defaultValue: "Cancel", comment: "Cancel an in-progress operation."),
                    action: cancel
                )
                .keyboardShortcut(.cancelAction)
                .frame(minWidth: 40, minHeight: 40)

                Spacer()

                Button(action: reopen) {
                    Label(
                        qfLocalized("auth.anthropic.openAgain", defaultValue: "Open browser again", comment: "Reopen the live Anthropic authorization URL."),
                        systemImage: "arrow.up.forward.app"
                    )
                }
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 40, minHeight: 40)
                .accessibilityIdentifier(AXIdentifiers.anthropicOpenBrowser)
            }
        }
    }
}
