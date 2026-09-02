import AppKit
import SwiftUI
import QotaFolioCore

/// The one sentence for an item macOS refused to host, drawn where the panel opens.
///
/// Control Center decides whether a third-party status item is on the bar, and its gate is
/// System Settings → Menu Bar → "Allow in the Menu Bar". A refused item is drawn into a window
/// nobody can see (`MenuBarPlacement`), so the panel — opened centred under the bar, as
/// `layoutPanel` does without an anchor — is the only place the person can be told.
public struct MenuBarPlacementAdvisoryRow: View {
    public init() {}

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "menubar.rectangle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: PanelMetrics.markSize, height: PanelMetrics.markSize)
                .accessibilityHidden(true)
            Text(qfLocalized(
                "placement.hidden",
                defaultValue: "macOS has hidden QotaFolio's batteries. Turn them on in System Settings → Menu Bar.",
                comment: "Panel advisory when macOS refused to place the status item on the menu bar, and where to allow it."
            ))
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                openMenuBarSettings()
            } label: {
                Text(qfLocalized("placement.openSettings", defaultValue: "Open…", comment: "Button on the hidden-item advisory that opens System Settings at the Menu Bar pane."))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: PanelMetrics.hitTarget)
            .help(qfLocalized("placement.openSettings.help", defaultValue: "Open System Settings → Menu Bar", comment: "Tooltip on the hidden-item advisory's button."))
        }
        .padding(PanelMetrics.cardPadding)
        .background { PanelPlate() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXIdentifiers.menuBarPlacementAdvisory)
    }

    private func openMenuBarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
