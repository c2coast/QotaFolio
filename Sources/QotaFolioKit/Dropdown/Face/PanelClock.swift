import SwiftUI
import QotaFolioCore

/// The instant every countdown on the panel is drawn for.
///
/// One `TimelineView` at the top of the card list sets it once a second; every reset label and
/// every spoken sentence below reads it. `nil` is a host that runs no clock — a test laying one
/// card out, a preview — and such a host reads the wall clock once.
private struct PanelNowKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

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
    var panelNow: Date? {
        get { self[PanelNowKey.self] }
        set { self[PanelNowKey.self] = newValue }
    }

    var requestPanelResize: @MainActor () -> Void {
        get { self[RequestPanelResizeKey.self] }
        set { self[RequestPanelResizeKey.self] = newValue }
    }

    /// The person's locale, calendar and clock, as one value the words are spelled with.
    var sentenceStyle: SentenceStyle {
        SentenceStyle(locale: locale, calendar: calendar, timeZone: timeZone)
    }
}

/// The one clock the panel runs, gated on the surface being on screen.
///
/// SwiftUI does not suspend a periodic `TimelineView` when its window leaves the screen, and the
/// panel's hosting controller outlives its window (`PanelEnvironment.swift`), so the clock stops
/// itself when the surface is off screen and the content reads one wall-clock instant instead.
struct PanelClock<Content: View>: View {
    @Environment(\.surfaceIsOnScreen) private var surfaceIsOnScreen
    @ViewBuilder let content: Content

    var body: some View {
        if surfaceIsOnScreen {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content.environment(\.panelNow, context.date)
            }
        } else {
            content.environment(\.panelNow, .now)
        }
    }
}
