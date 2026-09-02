import AppKit

import QotaFolioCore

@MainActor public final class AppKitStatusItemSurface: NSObject, StatusItemSurface, NSMenuDelegate {
    internal let statusItem: NSStatusItem
    internal var rightClickMenu: NSMenu?
    public weak var panel: (any PanelToggling)?

    private let renderer: StatusStripRenderer
    private let appearanceProbe: EffectiveAppearanceProbe
    private var lastStrip: StatusStripModel?
    private var lastColourless = false
    private var lastShows: StripShows = .session
    private var isRemoved = false
    private var placementSettleTimer: Timer?
    public var onPlacementChange: (() -> Void)?

    /// How long the item's window must hold still before its frame is taken as an answer.
    ///
    /// Measured on this Mac: while macOS places an accepted item its window passes through
    /// origin (0, −22) at height 22 — which is exactly the shape a REFUSED item has on
    /// another Mac — then (1401, 870) at height 30, then (0, −15), and settles at (739, 870). The
    /// whole dance takes about 120 ms. Any single frame read during it is a coin toss, so
    /// the question is only asked of a window that has stopped moving. A quarter of a second
    /// is twice the observed settling time and far below anything a person notices.
    static let placementSettleInterval: TimeInterval = 0.25

    public init(rightClickMenu: NSMenu? = nil) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.rightClickMenu = rightClickMenu
        self.renderer = StatusStripRenderer()
        self.appearanceProbe = EffectiveAppearanceProbe(frame: .zero)
        super.init()

        // Derived from the bundle identifier, so the name AppKit writes the position under and
        // the preferences domain "Remove My Data" empties can never drift apart.
        statusItem.autosaveName = AppIdentity.current.statusItemAutosaveName
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.target = self
            button.action = #selector(statusButtonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("QotaFolio")
            button.setAccessibilityHelp(
                qfLocalized(
                    "strip.ax.help",
                    defaultValue: "Open QotaFolio remaining quota",
                    comment: "VoiceOver help for the native status-item button."
                )
            )
            button.setAccessibilityIdentifier(AXIdentifiers.statusItem)

            appearanceProbe.frame = button.bounds
            appearanceProbe.autoresizingMask = [.width, .height]
            appearanceProbe.onAppearanceChange = { [weak self] in
                self?.refreshAppearance(invalidateCache: false)
            }
            appearanceProbe.onWindowChange = { [weak self] in
                self?.watchPlacement()
            }
            button.addSubview(appearanceProbe, positioned: .below, relativeTo: nil)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    /// The only truth about ink polarity, and only once the item is placed: the menu bar on
    /// macOS 26 is transparent and follows the wallpaper, so `NSApp.effectiveAppearance`
    /// answers a different question.
    public var currentAppearance: MenuBarAppearance {
        guard let button = statusItem.button else { return .aqua }
        let match = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .darkAqua : .aqua
    }

    public var placement: MenuBarPlacement {
        menuBarPlacement(ofStatusItemWindowFrame: statusItem.button?.window?.frame)
    }

    /// Where the batteries are on screen, in screen coordinates, once macOS has placed the item.
    /// The fixture runtime draws its backdrop's strip here so a photograph shows the real bar's
    /// geometry.
    public var statusButtonScreenFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    public var placementDescription: String {
        guard let frame = statusItem.button?.window?.frame else { return "absent" }
        return "origin (\(frame.origin.x), \(frame.origin.y)) size \(frame.width) x \(frame.height)"
    }

    public func apply(
        _ strip: StatusStripModel,
        appearance: MenuBarAppearance,
        colourless: Bool,
        showing: StripShows
    ) {
        lastStrip = strip
        lastColourless = colourless
        lastShows = showing
        guard let button = statusItem.button else { return }

        // Read here, at the call site, and handed to the renderer as two plain arguments —
        // so a test, the lab and a debug launch can draw every accommodation form without
        // anybody changing a setting on the Mac they are running on.
        let accessibility = NSWorkspace.shared
        var increaseContrast = accessibility.accessibilityDisplayShouldIncreaseContrast
        var differentiateWithoutColor = accessibility.accessibilityDisplayShouldDifferentiateWithoutColor
        #if DEBUG
        let overrides = DebugAccommodations()
        increaseContrast = increaseContrast || overrides.increaseContrast
        differentiateWithoutColor = differentiateWithoutColor || overrides.differentiateWithoutColor
        #endif

        button.image = renderer.image(
            for: strip.cells,
            appearance: appearance,
            increaseContrast: increaseContrast,
            differentiateWithoutColor: differentiateWithoutColor || colourless,
            showing: showing
        )
        button.imageScaling = .scaleNone
        statusItem.length = StatusStripRenderer.itemLength(cellCount: strip.cells.count)
        button.toolTip = strip.toolTip
        // The whole strip is one sentence, and it is re-read on every render,
        // because every render is a new set of numbers.
        button.setAccessibilityLabel(strip.accessibilityLabel)
    }

    public func showPanel() {
        guard let button = statusItem.button else { return }
        // A refused item's window frame is nonsense, so anchoring the panel to it would put
        // the panel somewhere nobody asked for. Centred under the menu bar is where a panel
        // with no anchor belongs.
        if placement == .hiddenByMenuBarSettings {
            panel?.showUnanchored(from: button)
            return
        }
        panel?.show(relativeTo: button)
    }

    public func togglePanel() {
        guard statusItem.button != nil else { return }
        if panel?.isPanelShown == true {
            panel?.hide(reason: .statusItemToggle)
            return
        }
        showPanel()
    }

    public func remove() {
        prepareForRemoval()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    public func clearSavedStateAndRemove() {
        prepareForRemoval()
        statusItem.autosaveName = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    @objc func statusButtonClicked(_ sender: NSStatusBarButton) {
        handleStatusButtonClick(sender)
    }

    @objc private func accessibilityDisplayOptionsChanged(_ notification: Notification) {
        refreshAppearance(invalidateCache: true)
    }

    /// Follows the item's window until macOS has finished deciding where to put it.
    ///
    /// The window arrives unsized — measured here at origin (0, 0), height 0 — and is moved
    /// and sized afterwards, so the first frame answers nothing. These two notifications are
    /// the moments the answer can change, and there is no third.
    private func watchPlacement() {
        guard !isRemoved else { return }
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didMoveNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
        if let window = statusItem.button?.window {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                center.addObserver(
                    self,
                    selector: #selector(statusItemWindowGeometryChanged(_:)),
                    name: name,
                    object: window
                )
            }
        }
        scheduleSettledPlacementRead()
    }

    @objc private func statusItemWindowGeometryChanged(_ notification: Notification) {
        scheduleSettledPlacementRead()
    }

    private func scheduleSettledPlacementRead() {
        placementSettleTimer?.invalidate()
        let timer = Timer(
            timeInterval: Self.placementSettleInterval,
            target: self,
            selector: #selector(placementSettled),
            userInfo: nil,
            repeats: false
        )
        timer.tolerance = Self.placementSettleInterval / 2
        placementSettleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func placementSettled() {
        placementSettleTimer = nil
        guard !isRemoved else { return }
        onPlacementChange?()
    }

    private func refreshAppearance(invalidateCache: Bool) {
        guard let lastStrip, !isRemoved else { return }
        if invalidateCache { renderer.invalidate() }
        apply(lastStrip, appearance: currentAppearance, colourless: lastColourless, showing: lastShows)
    }

    private func prepareForRemoval() {
        guard !isRemoved else { return }
        isRemoved = true
        appearanceProbe.onAppearanceChange = nil
        appearanceProbe.onWindowChange = nil
        placementSettleTimer?.invalidate()
        placementSettleTimer = nil
        onPlacementChange = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
