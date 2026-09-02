import SwiftUI
import QotaFolioCore

public struct PreConnectDisclosure: View {
    public init() {}

    public var body: some View {
        Label {
            Text(qfLocalized(
                "auth.disclosure",
                defaultValue: "QotaFolio reads usage from your own account through the provider's sign-in, stores its token only in this Mac's Keychain, and is independent and not affiliated with Anthropic or OpenAI.",
                comment: "Read-only OAuth and non-affiliation disclosure shown before provider handoff."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AXIdentifiers.authDisclosure)
    }
}
