import SwiftUI
import QotaFolioCore

/// How the card list tells the panel its height has changed.
///
/// A card whose content changes — a window the provider added, a state line, an instrument opened
/// — changes the height of the glass, and the panel's window is clear, so what is drawn in it is
/// the only outline AppKit has to work from. The list measures itself and calls this; the panel
/// publishes the new outline.
private struct RequestPanelResizeKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    var requestPanelResize: @MainActor () -> Void {
        get { self[RequestPanelResizeKey.self] }
        set { self[RequestPanelResizeKey.self] = newValue }
    }

    /// The person's locale, calendar and clock, as one value the words are spelled with.
    var sentenceStyle: SentenceStyle {
        SentenceStyle(locale: locale, calendar: calendar, timeZone: timeZone)
    }
}

/// The one clock the panel runs, gated on the surface being on screen: it hands its content the
/// instant every row and every spoken sentence is said at, at each minute, the finest step the
/// panel's words take.
///
/// SwiftUI does not suspend a periodic `TimelineView` when its window leaves the screen, and the
/// panel's hosting controller outlives its window (`PanelEnvironment.swift`), so the clock stops
/// itself when the surface is off screen and the content reads one wall-clock instant instead.
struct PanelClock<Content: View>: View {
    @Environment(\.surfaceIsOnScreen) private var surfaceIsOnScreen
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if surfaceIsOnScreen {
            TimelineView(.everyMinute) { context in content(context.date) }
        } else {
            content(.now)
        }
    }
}
