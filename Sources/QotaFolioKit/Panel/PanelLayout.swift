import Kit

/// The panel window's numbers, design values each, with their reasons in `design/tokens.json`.
public nonisolated enum PanelLayout {
    public static let width: Double = Tokens.Panel.width
    public static let preferredMaxHeight: Double = Tokens.Panel.maxHeight
    /// The glass slab's corner.
    public static let cornerRadius: Double = Tokens.Panel.radius
    /// The room the window keeps around the slab, for the glass's own shadow to fall into.
    ///
    /// Liquid Glass draws a shadow of its own when it is in a panel, and the panel draws none.
    /// Measured on macOS 26.4 at the slab's own size, with nothing else on the window: a
    /// Gaussian of sigma 16 points, eight points down, a quarter of black under the slab. That
    /// is the window server's own shadow for a window of this kind at twice the blur, which is
    /// what glass at a panel's size is given. It reaches 22 points above the slab, 30 either
    /// side and 38 below. Being the material's rather than the window's, it travels with the
    /// glass, and it deepens over text and lightens over a light background by itself.
    ///
    /// These numbers are that shadow's own extent: two sigma, and the offset either way. Two
    /// sigma out the shadow has fallen to one part in 255, so the window can end there and no
    /// edge is seen. A shorter room cuts the falloff at the same distance on every side and
    /// leaves a straight edge of six to ten parts in a hundred, which reads as a ring drawn
    /// round the panel rather than as depth under it.
    ///
    /// The window's own shadow stays off. It is traced on the window, and the window stands
    /// still at the full height the panel is allowed while the glass moves inside it.
    public static let shadowRoom = (top: Tokens.Panel.shadowRoomTop, side: Tokens.Panel.shadowRoomSide, bottom: Tokens.Panel.shadowRoomBottom)
    /// The window's width: the slab, and the room its shadow needs either side of it.
    public static var windowWidth: Double { width + shadowRoom.side * 2 }
    public static let cardGap: Double = Tokens.Panel.cardGap
    public static let panelPadding: Double = Tokens.Panel.padding
    public static let anchorGap: Double = Tokens.Panel.anchorGap
}
