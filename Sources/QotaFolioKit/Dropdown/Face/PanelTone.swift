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

/// The panel's colour language.
///
/// One palette, the strip's: green while there is plenty, amber as it gets low, red at a fifth
/// or less. A card's bar is a LEVEL, not a verdict — it says how much of that window is gone
/// and nothing about what to do with it. Forecast tones live only in the instrument behind a
/// click.
struct PanelTone {
    let scheme: ColorScheme
    let contrast: ColorSchemeContrast

    var increased: Bool { contrast == .increased }
    private var dark: Bool { scheme == .dark }

    // MARK: The level, in three steps

    func colour(_ level: Level) -> Color {
        level.colour(dark: dark, increased: increased).color()
    }

    /// A window's own level, from the share of it already spent: green under half used, amber
    /// up to four fifths, red past it.
    ///
    /// The used percentage goes through the app's own used-to-remaining conversion first, which
    /// is how every other surface arrives at a level. Deciding the step from the exact fraction
    /// here instead would put this bar one step away from the battery drawn above it for the
    /// same window, on the fractions the providers actually send.
    func level(_ usedPercent: Double) -> Color {
        colour(Level(remainingPercent: remainingPercent(fromUsedPercent: usedPercent) ?? 0))
    }

    // MARK: The instrument's verdicts (nothing on the resting card)

    /// The instrument's tone for a verdict. On course wears the green of a window with room
    /// left in it; cutting it close and running out take the amber and the red of the same
    /// three steps; spent is that red at rest. Every tone has the sentence under the chart
    /// beside it, so nothing rides on colour alone.
    ///
    /// A silence draws no projection at all, so this tone is never on screen; it is named
    /// anyway, because the alternative — leaving the case to a hierarchical style — paints the
    /// whole instrument in the system's accent colour.
    func verdict(_ verdict: WindowVerdict) -> Color {
        switch verdict {
        case .onCourse: colour(.plenty)
        case .cuttingItClose: colour(.low)
        case .runningOut, .spent: colour(.nearlyGone)
        case .silent: chartInk
        }
    }

    // MARK: Weights

    /// The instrument's band — how far the window could reach.
    var range: Double { Tokens.Chart.range(dark: dark, increased: increased) }

    /// The bar's neutral track: the whole window, unspent.
    ///
    /// A recess in the plate, in both appearances, and Increase Contrast deepens it. The panel's
    /// ink would be the obvious choice, and on a dark plate it is the wrong one: white ink moves
    /// the track TOWARD the bright fill lying in it, and Increase Contrast then moves it further,
    /// which is how the accessibility form ended up the least readable one in the app. A recess
    /// is also the ordinary reading of a meter — the track is the groove, the fill sits in it.
    var track: Color { Tokens.Surface.track(dark: dark, increased: increased).color() }
    /// Spent: the full red bar sits back — there is nothing to do about a window until it
    /// returns. A window merely nearly gone keeps full weight.
    var spent: Double { Tokens.Surface.spent(dark: dark, increased: increased) }

    // MARK: The instrument's chrome

    // Three weights of neutral for everything in the chart that is not the data: the ground
    // under it, the landmarks across it, and its own small print.
    //
    // Every one of them is written down here, because inside a `Chart` a hierarchical style has
    // no ink to step down from. It steps down the plot's content style instead, and for a chart
    // that names no style of its own that is the accent colour — which this app never set, so it
    // is the system's blue. The grid, the rules and the labels all come out blue, and worst on
    // a new account, whose forecast is silent and whose data line therefore has no colour of its
    // own either.
    //
    // Black on a light plate and white on a dark one, at a stated weight — the same form as
    // `track` above, and for the same reason. The chart lies on a plate that lies on glass, so
    // the surface under these tones moves with the desktop; a weight of ink follows it, where a
    // fixed grey would be a firm line over one wallpaper and invisible over the next. Increase
    // Contrast deepens all three.
    //
    // The weights are set against the plate as it actually renders, sampled off the panel on
    // this Mac: the grid lands at 1.4 to 1.5 against it in both appearances, the reset's rule at
    // 2.1 to 2.4, and the small print near 6, which is where a secondary label sits.

    /// The ruled ground: the guide lines at half and full, and the hours under them. The
    /// faintest thing on the plate — it is there to be measured against, not read.
    var chartGrid: Color { Tokens.Chart.grid(dark: dark, increased: increased).color() }

    /// A landmark across the plot: the reset, where the window ends.
    var chartRule: Color { Tokens.Chart.rule(dark: dark, increased: increased).color() }

    /// The chart's own words — the hour labels and the reset's clock — and the line under the
    /// cursor, which is read as closely as they are.
    var chartInk: Color { Tokens.Chart.smallPrint(dark: dark, increased: increased).color() }

    /// The hole through the point under the cursor, which is what makes that point a ring.
    ///
    /// It is drawn over the dot, so what shows through is the window's own colour taken toward
    /// the plate: lightened on a light plate, darkened on a dark one. Naming a colour for it is
    /// the obvious move and it does not work — the plate carries the desktop through the glass,
    /// so it has a chroma nothing can predict, and a grey of exactly the right lightness still
    /// reads as a smudge in the middle of the dot rather than a hole through it. A weight leans
    /// the way the plate leans and can never arrive as a foreign colour.
    var chartHole: Color { Tokens.Chart.hole(dark: dark, increased: increased).color() }
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
        Tokens.Surface.slabTint(dark: scheme == .dark, increased: false).color()
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
        return AnyShapeStyle(look(Tokens.Surface.plateFill).color(lift: lift))
    }

    /// The plate's one edge: lit along the top where the material's own light comes from,
    /// and seated in a shadow along the bottom. Both are needed — over a bright desktop the
    /// light half disappears and the shadow is what holds the plate off the glass; over a dark
    /// one it is the other way round.
    private var edge: LinearGradient {
        let top = look(Tokens.Surface.plateEdgeTop).color()
        let bottom = look(Tokens.Surface.plateEdgeBottom).color()
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }

    private func look(_ value: Translucent<Colour>) -> Colour {
        value(dark: dark, increased: increased, reduceTransparency: reduceTransparency)
    }
}
