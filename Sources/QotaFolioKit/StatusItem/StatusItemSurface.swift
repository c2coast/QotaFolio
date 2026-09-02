import QotaFolioCore

@MainActor public protocol StatusItemSurface: AnyObject {
    /// `colourless` is the privacy blanket: the batteries in ink alone, as Differentiate Without
    /// Colour draws them, so a shared screen shows levels and no provider. `showing` is which
    /// quantity the batteries are drawn to, which is the person's own choice.
    func apply(
        _ strip: StatusStripModel,
        appearance: MenuBarAppearance,
        colourless: Bool,
        showing: StripShows
    )
    var currentAppearance: MenuBarAppearance { get }
    /// Whether macOS actually put the item on the bar. Answered only after a first `apply`,
    /// because the window it is read from does not exist until then.
    var placement: MenuBarPlacement { get }
    /// The window frame `placement` was read from, for the one log line that records it.
    var placementDescription: String { get }
    /// Called when the answer to `placement` may have changed — which is when the item's
    /// window arrives, and never on a schedule this app controls.
    var onPlacementChange: (() -> Void)? { get set }
    var panel: (any PanelToggling)? { get set }

    func showPanel()
    /// The keyboard's click: shows the panel, or puts it away if it is up.
    func togglePanel()
    func remove()
    func clearSavedStateAndRemove()
}
