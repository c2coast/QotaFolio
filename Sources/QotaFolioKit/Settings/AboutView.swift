import SwiftUI
import QotaFolioCore

public struct AboutView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text("QotaFolio")
                .font(.title.weight(.semibold))

            Text(versionText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(qfLocalized(
                "about.nonAffiliation",
                defaultValue: "Anthropic, Claude, OpenAI, and ChatGPT are trademarks of their respective owners. QotaFolio is an independent product and is not affiliated with, endorsed by, or sponsored by Anthropic or OpenAI.",
                comment: "Required trademark and non-affiliation statement."
            ))
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 440)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return qfLocalized(
            "about.version",
            defaultValue: "Version \(version) (\(build))",
            comment: "App version and build number."
        )
    }
}
