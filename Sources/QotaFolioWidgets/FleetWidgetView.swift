import QotaFolioModel
import SwiftUI
import WidgetKit

/// The widget's face: rings in a grid when small, ring-and-numbers rows when medium. The two
/// account views live in `Sources/Surfaces` — the app's fixture runtime hosts the same views
/// for photographs.
struct FleetWidgetView: View {
    let entry: FleetEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch entry.availability {
        case .noApp:
            emptyState(String(localized: "No accounts yet", comment: "Widget body when the app has no accounts."),
                       String(localized: "Open QotaFolio to add one.", comment: "Widget body, second line, when the app has no accounts."))
        case .unreadable:
            emptyState(String(localized: "QotaFolio can't read its files", comment: "Widget body when the shared files cannot be read."),
                       String(localized: "Open QotaFolio for details.", comment: "Widget body, second line, when the shared files cannot be read."))
        case .reading(let reading):
            if reading.accounts.isEmpty {
                emptyState(String(localized: "No accounts yet", comment: "Widget body when the app has no accounts."),
                           String(localized: "Open QotaFolio to add one.", comment: "Widget body, second line, when the app has no accounts."))
            } else if family == .systemSmall {
                SmallFleetView(reading: reading, now: entry.date)
            } else {
                MediumFleetView(reading: reading, now: entry.date)
            }
        }
    }

    private func emptyState(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}
