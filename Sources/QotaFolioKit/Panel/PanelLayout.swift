public nonisolated enum PanelLayout {
    public static let width: Double = 408
    public static let preferredMaxHeight: Double = 704
    /// The glass slab's corner.
    public static let cornerRadius: Double = 24
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
    public static let shadowRoom = (top: 24.0, side: 32.0, bottom: 40.0)
    /// The window's width: the slab, and the room its shadow needs either side of it.
    public static var windowWidth: Double { width + shadowRoom.side * 2 }
    public static let cardGap: Double = 10
    public static let panelPadding: Double = 12
    public static let anchorGap: Double = 6
}
