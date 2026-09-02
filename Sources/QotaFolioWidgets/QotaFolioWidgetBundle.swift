import SwiftUI
import WidgetKit

/// Everything QotaFolio offers outside its own windows: the desktop widget and the Control.
@main
struct QotaFolioWidgetBundle: WidgetBundle {
    var body: some Widget {
        FleetWidget()
        AccountControl()
    }
}

/// The kind strings, spelled once. The app reloads by these names.
nonisolated enum SurfaceKind {
    static let fleetWidget = "QotaFolio.Fleet"
    static let accountControl = "QotaFolio.Account"
}
