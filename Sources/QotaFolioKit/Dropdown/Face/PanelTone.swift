import Graph
import Kit
import QotaFolioCore
import SwiftUI

nonisolated enum PanelMetrics {
    static let panelRadius: CGFloat = PanelLayout.cornerRadius
    static let panelPadding: CGFloat = PanelLayout.panelPadding
    static let cardRadius: CGFloat = panelRadius - panelPadding
    static let cardPadding: CGFloat = Tokens.Panel.cardPadding
    static let cardGap: CGFloat = PanelLayout.cardGap
    static let barHeight: CGFloat = Tokens.Panel.barHeight
    static let nameColumn: CGFloat = Tokens.Panel.nameColumn
    static let percentColumn: CGFloat = Tokens.Panel.percentColumn
    static let markSize: CGFloat = Tokens.Panel.markSize
    static let hitTarget: CGFloat = Tokens.Panel.hitTarget
    static let glyphWell: CGFloat = Tokens.Panel.glyphWell
    static let headerHeight: CGFloat = Tokens.Panel.headerHeight
}

/// The panel's own chrome, outside a card: the footer's buttons and the cards' actions menu.
enum PanelChrome {
    /// The wash under a hovered control. One number, so every control on the panel lifts by
    /// the same amount.
    static func hoverWash(_ contrast: ColorSchemeContrast) -> Double {
        Tokens.Surface.hoverWash(dark: false, increased: contrast == .increased)
    }
}

/// The panel's one slab of glass.
enum PanelSlab {
    /// The neutral the slab's glass is tinted toward: the panel's own surface, light or dark.
    ///
    /// Set against the glass Apple's own panels are cut from, photographed at the same rect
    /// over the same wallpaper on this Mac. At those two values the slab lands on that glass:
    /// in light, a mean saturation of 0.46 against Apple's 0.46 where untinted Regular leaves
    /// 0.61; in dark, 0.39 against 0.38. Not a preference — the number the material next to
    /// ours already holds.
    static func tint(_ scheme: ColorScheme) -> Color {
        Tokens.Surface.slabTint(dark: scheme == .dark, increased: false).color(dark: scheme == .dark)
    }
}

/// A plate on the panel's glass: a card, an advisory, the add-account sheet.
///
/// A flat fill, never a material. A material inside the slab is a second backdrop sampler:
/// it takes its own blurred copy of the desktop, at its own scale, without seeing the glass
/// it lies on. The wallpaper then appears twice, at two blurs and two saturations, with a seam
/// at every plate edge. Apple's rule for anything placed on Liquid Glass is the same one from
/// the other side: fills, transparency and vibrancy, so the plate reads as part of the material
/// rather than a hole through it.
///
/// The fill is white in both appearances, because a plate is lighter than the glass it lies
/// on either way, and the plate has one edge: lit at the top, shadowed at the bottom, the way
/// a real plate lying on glass takes the light. One edge per surface — the glass draws its own.
struct PanelPlate: View {
    var cornerRadius: CGFloat = PanelMetrics.cardRadius
    var isHovered: Bool = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(fill)
            .overlay { shape.strokeBorder(edge, lineWidth: 1) }
            .animation(PanelMotion.hover, value: isHovered)
    }

    private var increased: Bool { contrast == .increased }
    private var dark: Bool { scheme == .dark }

    /// The plate's own tone.
    ///
    /// Under Reduce Transparency the slab has gone opaque and a white plate would vanish into
    /// it, so the plate turns to the surface's own ink and separates by depth instead.
    private var fill: AnyShapeStyle {
        let lift = isHovered ? Tokens.Surface.plateHoverLift(dark: dark, increased: increased) : 0
        return AnyShapeStyle(look(Tokens.Surface.plateFill).color(dark: dark, lift: lift))
    }

    /// The plate's one edge: lit along the top where the material's own light comes from,
    /// and seated in a shadow along the bottom. Both are needed — over a bright desktop the
    /// light half disappears and the shadow is what holds the plate off the glass; over a dark
    /// one it is the other way round.
    private var edge: LinearGradient {
        let top = look(Tokens.Surface.plateEdgeTop).color(dark: dark)
        let bottom = look(Tokens.Surface.plateEdgeBottom).color(dark: dark)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    private func look(_ value: Translucent<Colour>) -> Colour {
        value(dark: dark, increased: increased, reduceTransparency: reduceTransparency)
    }
}
