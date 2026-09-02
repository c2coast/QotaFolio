import AppKit

@MainActor public final class MenuBarPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .popUpMenu
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        // The glass carries the shadow. The window's own would be a second one on top of it,
        // traced on a window that stands still while the glass moves — see
        // `PanelLayout.shadowRoom`.
        hasShadow = false
        isMovable = false
        autorecalculatesKeyViewLoop = true
        collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        animationBehavior = .utilityWindow
    }
}
