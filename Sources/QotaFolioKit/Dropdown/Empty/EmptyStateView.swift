import SwiftUI
import QotaFolioCore

public struct EmptyStateView: View {
    private let catalog: any AccountCataloging
    private let store: any AccountsStoring
    private let addFlow: any AddFlowPresenting

    public init(
        catalog: any AccountCataloging,
        store: any AccountsStoring,
        addFlow: any AddFlowPresenting
    ) {
        self.catalog = catalog
        self.store = store
        self.addFlow = addFlow
    }

    public var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                BrandAssetLoader.image(.qotaFolioGlyph)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)

                Text(qfLocalized("empty.title", defaultValue: "No accounts yet", comment: "First-run empty-state title."))
                    .font(.title3.weight(.semibold))

                Text(qfLocalized(
                    "empty.body",
                    defaultValue: "Add up to five accounts to see remaining quota and reset times in one place.",
                    comment: "First-run empty-state explanation."
                ))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            if let advisory = catalog.recoveryAdvisory {
                CatalogRecoveryAdvisoryRow(advisory: advisory, loadState: catalog.loadState)
            }

            Button {
                addFlow.beginAddFlow()
            } label: {
                Label(
                    qfLocalized("empty.primaryAction", defaultValue: "Add your first account…", comment: "Primary first-run add-account button."),
                    systemImage: "plus.circle.fill"
                )
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("n", modifiers: .command)
            .disabled(catalog.loadState == .unreadable)
            .accessibilityIdentifier(AXIdentifiers.footerAddAccount)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(24)

        PanelFooterView(
            catalog: catalog,
            store: store,
            addFlow: addFlow,
            hasAccount: false,
            showsAddButton: false
        )
    }
}
