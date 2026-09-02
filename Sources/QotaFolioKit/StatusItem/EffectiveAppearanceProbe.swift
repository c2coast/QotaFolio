import AppKit

@MainActor final class EffectiveAppearanceProbe: NSView {
    var onAppearanceChange: (() -> Void)?
    /// Fires when the status button gains or loses its window.
    ///
    /// That moment is the only signal an app gets that macOS has decided where — or
    /// whether — to put the item: a status item's window is created by Control Center after
    /// the app asks for one, so nothing the app does synchronously can read it.
    var onWindowChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}
