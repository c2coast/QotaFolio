import AppKit

extension AppKitStatusItemSurface {
    func handleStatusButtonClick(_ sender: NSStatusBarButton) {
        let isSecondary = NSApp.currentEvent.map { event in
            event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        } ?? false

        guard isSecondary, let menu = rightClickMenu else {
            panel?.togglePanel(relativeTo: sender)
            return
        }

        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    public func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }
}
