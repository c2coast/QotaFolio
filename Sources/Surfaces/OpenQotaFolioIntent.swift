import AppIntents
import Foundation

/// Where in QotaFolio an open lands. One place today: the panel is the app.
nonisolated enum QotaFolioDestination: String, AppEnum, Sendable {
    case panel

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "QotaFolio")
    static let caseDisplayRepresentations: [QotaFolioDestination: DisplayRepresentation] = [
        .panel: "Panel",
    ]
}

/// Opens QotaFolio and shows the panel.
///
/// The Control's click, and a Shortcuts action. An `OpenIntent`, because that is what makes a
/// control button launch its app: the system brings the app forward and performs the intent
/// there. Apple requires the type in both the app and the extension, so this file is compiled
/// into both; only the app has a panel to show, and `QotaFolioIntentRuntime` is how it finds it.
// Not `nonisolated` on the type: `@Parameter` is a mutable stored property and the modifier
// cannot apply to it. `AppIntent` itself requires Sendable, so the conformance carries it.
struct OpenQotaFolioIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open QotaFolio"
    static let description = IntentDescription("Shows the QotaFolio panel with every account's current usage.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Show")
    var target: QotaFolioDestination

    init() {
        target = .panel
    }

    init(target: QotaFolioDestination) {
        self.target = target
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open QotaFolio")
    }

    func perform() async throws -> some IntentResult {
        await QotaFolioIntentRuntime.revealPanel()
        return .result()
    }
}

/// How an intent reaches the running app's surfaces, when it runs in the app.
///
/// In the widget extension there is no panel; `revealPanel` does nothing there and the system's
/// own launch of the app is the whole action. The app installs its handlers at start.
@MainActor
enum QotaFolioIntentRuntime {
    private static var revealPanelHandler: (@MainActor () -> Void)?

    static func install(revealPanel: @escaping @MainActor () -> Void) {
        revealPanelHandler = revealPanel
    }

    static func revealPanel() {
        revealPanelHandler?()
    }
}
