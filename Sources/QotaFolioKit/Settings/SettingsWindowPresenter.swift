import AppKit
import Observation
import SwiftUI
import QotaFolioCore

public extension Notification.Name {
    nonisolated static let qotaFolioUninstallRecoveryPresentationRequested = Notification.Name(
        "net.c2coast.QotaFolio.uninstallRecovery.presentSettings"
    )
}

@MainActor @Observable public final class SettingsWindowPresenter: NSObject, NSWindowDelegate, SettingsAddFlowPresenting {
    /// The menu-bar panel, handed here by the composition root.
    ///
    /// The wiring goes both ways on this one assignment. Settings uses the panel to get it off
    /// screen; the panel uses Settings to answer whether the add-account flow is somewhere else.
    /// Installing the back-reference here means the composition root states the relationship
    /// once, in the line it already had.
    @ObservationIgnored public weak var panel: (any PanelToggling)? {
        didSet { panel?.settingsAddFlowSurface = self }
    }

    private let updater: any SettingsUpdating
    private let launchAtLogin: any LoginAtStartupControlling
    private let catalog: any AccountCataloging
    private let addFlow: any AddFlowPresenting
    private let visibility: any AccountVisibilityControlling
    private let uninstall: any UninstallPresenting
    private let alertPreferences: AlertPreferences
    private let alerts: AlertDeliverer
    private let privacy: ScreenPrivacy
    private let panelShortcut: GlobalShortcutStore
    private let appearance: AppearancePreferences
    private let stripShows: StripPreferences
    /// The tab the window opens on the first time. The lab photographs one tab at a time.
    public var initialTab: SettingsTab = .general
    @ObservationIgnored private var controller: NSWindowController?

    /// Whether the Settings window is on screen.
    ///
    /// Observed, not derived from `NSWindow.isVisible`: AppKit's flag is not observable, so a
    /// panel that read it would keep drawing whatever it saw the last time it happened to render.
    public private(set) var windowIsOnScreen = false

    /// The Settings window this presenter owns.
    ///
    /// Not private, for the reason `MenuBarPanelController.panelWindow` is not: a suite that
    /// drives both surfaces has to act on the window this presenter built and on no other. A
    /// window found by title is whichever one AppKit lists first, and `isReleasedWhenClosed` is
    /// false here, so closed windows stay listed.
    var presentedWindow: NSWindow? { controller?.window }

    public init(
        updater: any SettingsUpdating,
        launchAtLogin: any LoginAtStartupControlling,
        catalog: any AccountCataloging,
        addFlow: any AddFlowPresenting,
        visibility: any AccountVisibilityControlling,
        uninstall: any UninstallPresenting,
        alertPreferences: AlertPreferences,
        alerts: AlertDeliverer,
        privacy: ScreenPrivacy,
        panelShortcut: GlobalShortcutStore,
        appearance: AppearancePreferences,
        stripShows: StripPreferences
    ) {
        self.updater = updater
        self.launchAtLogin = launchAtLogin
        self.catalog = catalog
        self.addFlow = addFlow
        self.visibility = visibility
        self.uninstall = uninstall
        self.alertPreferences = alertPreferences
        self.alerts = alerts
        self.privacy = privacy
        self.panelShortcut = panelShortcut
        self.appearance = appearance
        self.stripShows = stripShows
        super.init()
        watchAppearance()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(presentForUninstallRecovery(_:)),
            name: .qotaFolioUninstallRecoveryPresentationRequested,
            object: nil
        )
    }

    @objc private func presentForUninstallRecovery(_ notification: Notification) {
        present()
    }

    /// True while the Settings window has the add-account flow on screen.
    ///
    /// The sheet's own presentation condition, plus the window being there to present it. Every
    /// input is observable, so a SwiftUI body that reads this re-renders when the answer changes.
    public var settingsIsPresentingAddFlow: Bool {
        guard windowIsOnScreen else { return false }
        return settingsPresentsAddFlow(addFlow.activeFlow, uninstallState: uninstall.state)
    }

    public func present() {
        panel?.hide(reason: .supersededBySettings)
        NSApp.activate()

        if controller == nil {
            controller = makeController()
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        windowIsOnScreen = true
    }

    /// Bringing the flow's surface forward is opening Settings, which is what this already does.
    public func bringAddFlowSurfaceForward() {
        present()
    }

    /// The window closing is what takes the flow's second surface away again.
    ///
    /// It cannot happen with the add-flow sheet up — an attached sheet disables the window's own
    /// close button and takes the keystroke — so this is the ordinary case of a user closing
    /// Settings, and it hands the flow back to the panel for the next time one is live.
    public func windowWillClose(_ notification: Notification) {
        guard (notification.object as AnyObject?) === controller?.window else { return }
        windowIsOnScreen = false
    }

    /// Keeps the window in the appearance the person chose, while they are choosing it.
    ///
    /// Set on the window rather than on the view, so the title bar changes with the content — a
    /// dark form under a light title bar is a window that looks broken. A registration fires once,
    /// so it is re-armed after every change; the same shape `StatusItemController` uses to watch
    /// the catalog.
    private func watchAppearance() {
        withObservationTracking {
            _ = appearance.appearance
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.controller?.window?.appearance = self.appearance.nsAppearance
                self.watchAppearance()
            }
        }
    }

    private func makeController() -> NSWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = qfLocalized("settings.window.title", defaultValue: "QotaFolio Settings", comment: "Title of the AppKit-owned Settings window.")
        window.isReleasedWhenClosed = false
        window.preventsApplicationTerminationWhenModal = false
        window.contentView = NSHostingView(
            rootView: SettingsView(
                updater: updater,
                launchAtLogin: launchAtLogin,
                catalog: catalog,
                addFlow: addFlow,
                visibility: visibility,
                uninstall: uninstall,
                alertPreferences: alertPreferences,
                alerts: alerts,
                privacy: privacy,
                panelShortcut: panelShortcut,
                appearance: appearance,
                stripShows: stripShows,
                initialTab: initialTab
            )
        )
        window.appearance = appearance.nsAppearance
        window.center()
        window.delegate = self
        return NSWindowController(window: window)
    }
}
