import AppKit
import QotaFolioCore

@MainActor public final class PanelDismissalMonitor: EscapeInterceptable {
    /// The outer Escape claimant, installed by the composition root: the live add flow.
    public var escapeHandler: (() -> Bool)?

    /// The inner Escape claimant, installed by `MenuBarPanelController`: the account prompt.
    ///
    /// Claimants are tried innermost first, so the question nearest the user is the one Escape
    /// answers. Each returns true when it took the key.
    var panelEscapeClaimant: (() -> Bool)?

    /// Whether the add-account flow is on the panel, installed by `MenuBarPanelController`.
    ///
    /// The outer claimant cancels or acknowledges the flow directly, and the flow has two
    /// surfaces. Escape aimed at a panel full of quota numbers must not reach into the Settings
    /// sheet the user is not looking at. Unset means this host has one surface and the outer
    /// claimant speaks for it, which is every build that installs no Settings window.
    var addFlowIsOnThePanel: (() -> Bool)?

    private weak var panel: NSPanel?
    private weak var statusButton: NSStatusBarButton?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var dismiss: ((PanelDismissReason) -> Void)?

    public init() {}

    public func start(
        panel: NSPanel,
        statusButton: NSStatusBarButton,
        dismiss: @escaping (PanelDismissReason) -> Void
    ) {
        stop()
        self.panel = panel
        self.statusButton = statusButton
        self.dismiss = dismiss

        let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [mouseEvents, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocal(event)
        }

        // A menu-bar panel closes as the user goes elsewhere: that is the convention, and it
        // needs a monitor that sees clicks this application never receives.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss?(.outsideApplicationClick)
            }
        }
    }

    public func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        panel = nil
        statusButton = nil
        dismiss = nil
    }

    /// Whether an event's window is the panel or a window the panel is responsible for.
    ///
    /// **Ancestry, never app ownership.** A local monitor runs synchronously, before the event
    /// reaches its target window, so whatever this answers happens to the event before any control
    /// sees it. Asking `event.window === panel` instead reads every window the panel itself put
    /// on screen as somewhere else.
    ///
    /// The opposite mistake would be to ask whether the window belongs to this application.
    /// Settings is this application's window, and clicking it must still dismiss the panel — the
    /// panel is a menu-bar surface, and a menu-bar surface closes when the user goes elsewhere,
    /// including elsewhere in the same app. Walking `sheetParent` and `parent` up from the event's
    /// window answers the question that actually matters: is this window part of the panel?
    private func isPanelDescendant(_ window: NSWindow?) -> Bool {
        guard let panel else { return false }
        var candidate = window
        while let current = candidate {
            if current === panel { return true }
            candidate = current.sheetParent ?? current.parent
        }
        return false
    }

    func handleLocal(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown, event.keyCode == 53 {
            // Escape is claimed only for the panel's own tree. Claiming it for the whole
            // application swallows the key in Settings, in Settings' sheets, and in every text
            // field of every other window this app will ever have, for as long as the panel
            // happens to be open.
            guard isPanelDescendant(event.window) else { return event }
            if panelEscapeClaimant?() == true {
                return nil
            }
            if addFlowIsOnThePanel?() != false, escapeHandler?() == true {
                return nil
            }
            dismiss?(.escape)
            return nil
        }

        // The panel's window is much larger than the glass, and none of the rest of it is the
        // panel's to answer for: the window server hands a window only the clicks that land on a
        // pixel it drew, and the glass's shadow is the compositor's rather than the window's.
        // Measured on the open panel — one point outside the slab's edge, and inside its corner
        // curve, the click goes straight through to whatever is behind. So a click beside the
        // panel is a click elsewhere, and it arrives below as one.
        if isPanelDescendant(event.window) {
            return event
        }

        if let statusButton,
           event.window === statusButton.window,
           statusButton.bounds.contains(statusButton.convert(event.locationInWindow, from: nil)) {
            return event
        }

        dismiss?(.outsideLocalClick)
        return event
    }

}
