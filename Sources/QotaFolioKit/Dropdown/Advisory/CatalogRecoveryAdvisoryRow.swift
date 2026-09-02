import SwiftUI
import QotaFolioCore

public struct CatalogRecoveryAdvisoryRow: View {
    public let advisory: CatalogRecoveryAdvisory
    public let loadState: CatalogLoadState

    public init(advisory: CatalogRecoveryAdvisory, loadState: CatalogLoadState) {
        self.advisory = advisory
        self.loadState = loadState
    }

    public var body: some View {
        if let presentation = CatalogAdvisoryPresentation.make(
            advisory: advisory,
            loadState: loadState
        ) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(presentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityValue)
            .accessibilityIdentifier(AXIdentifiers.catalogRecoveryAdvisory)
        }
    }
}
