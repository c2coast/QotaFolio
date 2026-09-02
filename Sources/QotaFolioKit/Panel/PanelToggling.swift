import AppKit
import QotaFolioCore

@MainActor public protocol PanelToggling: AnyObject {
    var isPanelShown: Bool { get }
    var dismissalMonitor: any EscapeInterceptable { get }

    /// The flow's other surface, installed by the Settings window when the app has one.
    ///
    /// nil means this build has no Settings window at all, which is the fixture runtime and the
    /// UI suites. A panel with no second surface presents every flow itself.
    var settingsAddFlowSurface: (any SettingsAddFlowPresenting)? { get set }

    func togglePanel(relativeTo button: NSStatusBarButton)
    func show(relativeTo button: NSStatusBarButton)
    /// Shows the panel without hanging it off the button's frame.
    ///
    /// For the one case where that frame is not a place on screen: macOS 26 refuses a status
    /// item behind "Allow in the Menu Bar" by handing the app a proxy window with a nonsense
    /// frame. The button is still passed, because the panel takes its appearance, its
    /// highlight and its dismissal monitor from it — only the position is unavailable.
    func showUnanchored(from button: NSStatusBarButton)
    func hide(reason: PanelDismissReason)
    func requestContentResize()
}

public nonisolated enum PanelDismissReason: Equatable, Sendable {
    case outsideApplicationClick
    case outsideLocalClick
    case statusItemToggle
    case escape
    case supersededBySettings
    case termination
}

/// Whether a panel dismissal is the user saying they are done with the failure on the panel.
///
/// The panel's own visibility does not answer it. Opening Settings hides the panel, so a failure
/// would not survive the trip to the window that is about to present it — and the system takes a
/// `.transient` panel off screen for Mission Control or a space change while the user is still
/// looking at it.
///
/// The question a dismissal has to answer is **"did the user dismiss this?"**, and only two
/// reasons say yes:
///
///   * `.statusItemToggle` — the user clicked the status item to put the panel away while the
///     failure was the thing on screen. There is no other reason to click it, and the failure is
///     terminal: nothing is running, Try again starts a fresh flow, and the whole content of the
///     step is one sentence they have now read.
///   * `.escape` — the key aimed at the panel's own tree, which is the user dismissing whatever
///     is in front of them. The composition root's Escape claimant normally acknowledges before
///     the panel is asked to hide at all; this answers the same way for a host that installs no
///     claimant, so the two paths cannot disagree.
///
/// The other four say no, and each for its own reason:
///
///   * `.supersededBySettings` — the app is moving the flow to Settings, not ending it.
///   * `.outsideLocalClick` — the user went to another window of this app, which is Settings,
///     which presents the same flow.
///   * `.outsideApplicationClick` — refused outright while the panel has the flow; the other
///     application is a browser this app opened, on a page it sent the user to.
///   * `.termination` — the app is quitting. A quit is not an answer to anything.
///
/// Exhaustive on purpose: a seventh dismissal reason cannot be added without deciding what it
/// means for a failure the user is looking at.
public nonisolated func panelDismissalAcknowledgesFailure(_ reason: PanelDismissReason) -> Bool {
    switch reason {
    case .statusItemToggle, .escape:
        true
    case .outsideApplicationClick, .outsideLocalClick, .supersededBySettings, .termination:
        false
    }
}
