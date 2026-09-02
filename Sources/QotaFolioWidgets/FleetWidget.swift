import QotaFolioModel
import SwiftUI
import WidgetKit

/// One entry of the widget's timeline: the reading, and the instant it is drawn for.
nonisolated struct FleetEntry: TimelineEntry, Sendable {
    let date: Date
    let availability: SurfaceReading.Availability
}

/// The widget's timeline: the reading now, then the same reading re-drawn at each upcoming
/// reset instant so a passed reset reads "Reset due" exactly as the panel does. The widget
/// never predicts a fresh window it has not seen. The app reloads the timeline on every real
/// change; these entries are what a sleeping app leaves behind.
nonisolated struct FleetTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> FleetEntry {
        FleetEntry(date: Date(), availability: .reading(SurfaceReading.preview))
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (FleetEntry) -> Void) {
        if context.isPreview {
            completion(FleetEntry(date: Date(), availability: .reading(SurfaceReading.preview)))
            return
        }
        completion(FleetEntry(date: Date(), availability: SurfaceReading.read()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<FleetEntry>) -> Void) {
        let now = Date()
        let availability = SurfaceReading.read(now: now)
        var entries = [FleetEntry(date: now, availability: availability)]
        var policy: TimelineReloadPolicy = .after(now.addingTimeInterval(30 * 60))
        if case .reading(let reading) = availability {
            let resets = Set(reading.accounts.flatMap { $0.windows.compactMap(\.resetsAt) })
                .filter { $0 > now }
                .sorted()
                .prefix(8)
            entries += resets.map { FleetEntry(date: $0, availability: availability) }
            if let last = resets.last {
                policy = .after(last.addingTimeInterval(30 * 60))
            }
        }
        completion(Timeline(entries: entries, policy: policy))
    }
}

/// The desktop widget: every account as a ring, small and medium.
struct FleetWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SurfaceKind.fleetWidget, provider: FleetTimelineProvider()) { entry in
            FleetWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("QotaFolio")
        .description(String(localized: "Every account's current usage, as rings.", comment: "Widget gallery description."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
