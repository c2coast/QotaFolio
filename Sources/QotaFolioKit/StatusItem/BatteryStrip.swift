import AppKit
import CoreGraphics

import QotaFolioCore

// ============================================================================
// THE STRIP — one Apple battery per account, in the panel's order.
// Leftmost battery = the top card in the panel. No number, no sorting, no
// grouping: one fill per battery, at the length of the quantity the person
// asked to see, coloured by how much of it is left, and every readable
// battery stands at full strength.
// ============================================================================

/// The colours one strip is drawn in.
///
/// Ink polarity is not a mode question. The menu bar on macOS 26 is transparent and follows
/// the wallpaper, so the only truth about it is `button.effectiveAppearance` after the item
/// is placed. Everything here is derived from that one answer plus the two accessibility
/// settings, and every one of them is a parameter — so a test or the lab can draw every form
/// without touching the Mac's settings.
nonisolated struct BatteryTheme: Hashable, Sendable {
    /// Apple's label colour for this bar: white on a dark bar, black on a light one.
    var ink: CGColor
    /// The weight an account that is not answering is outlined at.
    var dim: CGFloat
    var darkBar: Bool
    /// Increase Contrast is on: the level takes its deepened variant.
    var increasedContrast: Bool

    static func make(darkBar: Bool, contrast: Bool = false) -> BatteryTheme {
        let w: CGFloat = darkBar ? 1 : 0
        let ink = CGColor(red: w, green: w, blue: w, alpha: contrast ? 1.0 : (darkBar ? 1.0 : 0.90))
        return BatteryTheme(
            ink: ink,
            dim: contrast ? 0.80 : 0.55,
            darkBar: darkBar,
            increasedContrast: contrast
        )
    }

    /// What a battery with this share of its quantity left is drawn in: green with plenty of
    /// it, amber as it gets low, red at a fifth or less. One palette for every surface.
    func level(_ remainingPercent: Int) -> CGColor {
        colour(LevelPalette.ink(
            LevelPalette.band(remainingPercent: remainingPercent),
            onDark: darkBar,
            increasedContrast: increasedContrast
        ))
    }

    private func colour(_ ink: LevelPalette.Ink) -> CGColor {
        CGColor(red: ink.red, green: ink.green, blue: ink.blue, alpha: 1)
    }

    /// Nothing left of the quantity being shown — the red a level runs out in.
    var nothingToSpend: CGColor { level(0) }
}

nonisolated func batteryFade(_ colour: CGColor, _ alpha: CGFloat) -> CGColor {
    colour.copy(alpha: colour.alpha * alpha) ?? colour
}

/// How one battery is drawn: which quantity, at what size, in what form.
nonisolated struct BatteryOptions: Hashable, Sendable {
    /// Apple's small menu-bar battery, 19 x 10.
    var body: BatteryBody = .small
    var inset: CGFloat = 2.0
    var fillRadius: CGFloat = 1.0
    /// Differentiate Without Colour: every hue becomes the ink.
    var mono = false
    /// Which quantity the fill is drawn to — the person's own choice, from Settings.
    var shows: StripShows = .session
}

/// Where the batteries sit relative to each other.
nonisolated struct BatteryLayout: Hashable, Sendable {
    /// Ink edge to ink edge, the same between every pair. Six points was chosen over four and
    /// five by looking at all three on a real menu bar.
    var gap: CGFloat = 6.0
}

/// How strongly one battery is drawn.
nonisolated struct BatteryWeights: Hashable, Sendable {
    /// The weight of the fill and the cap.
    var fill: CGFloat
    /// The weight of the wall.
    var wall: CGFloat
}

/// The one place the strip decides a battery's weight.
///
/// Every readable battery — a full one, one that is nearly out, a spent one — stands at full strength:
/// the strip shows each account's level and says nothing about which to use. The one quiet
/// drawing is the outline of an account that is not answering, so the eye can tell "no
/// reading" from "empty" without any other mark.
nonisolated func batteryWeights(
    for cell: BatteryCell,
    dim: CGFloat
) -> BatteryWeights {
    switch cell.state {
    case .noReading:
        return BatteryWeights(fill: 1.0, wall: dim)
    case .low, .spent, .reading:
        return BatteryWeights(fill: 1.0, wall: 1.0)
    }
}

/// Draws one account's battery, with its origin at the bottom-left of the body.
nonisolated func drawBattery(
    _ ctx: CGContext,
    _ cell: BatteryCell,
    at origin: CGPoint,
    _ theme: BatteryTheme,
    _ options: BatteryOptions
) {
    let body = options.body
    let weights = batteryWeights(for: cell, dim: theme.dim)
    drawAppleBody(ctx, body, origin: origin, ink: batteryFade(theme.ink, weights.wall))

    if case .noReading = cell.state { return }

    // WHICH quantity the battery is drawn to is the person's own choice, and everything else
    // about the picture follows from that one figure: one fill, at that window's own length, in
    // that window's own colour. The other window stays in the words. A second length behind the
    // first cannot be drawn honestly — it is invisible whenever the drawn window is the
    // healthier of the two, and when it is not, a long pale bar behind a short bright one says
    // "plenty" and "nearly out" in one glance. Differentiate Without Colour drops the colour and
    // leaves the length.
    let figure = cell.figure(showing: options.shows)
    let hue = batteryFade(
        options.mono ? theme.ink : theme.level(figure.remainingPercent),
        weights.fill
    )

    ctx.saveGState()
    defer { ctx.restoreGState() }
    ctx.translateBy(x: origin.x, y: origin.y)
    let box = batteryFillBox(body, inset: options.inset)

    if figure.isSpent {
        // SPENT — Apple's residual: the hairline at the leading edge, in the colour a level runs
        // out in. The reset time lives in the tooltip and the panel, never in the strip.
        let hairline = CGRect(x: box.minX, y: box.minY, width: 1.0, height: box.height)
        ctx.addPath(CGPath(roundedRect: hairline, cornerWidth: 0.5, cornerHeight: 0.5, transform: nil))
        ctx.setFillColor(batteryFade(options.mono ? theme.ink : theme.nothingToSpend, weights.fill))
        ctx.fillPath()
        return
    }

    // A length floor of 1.2 pt: a bar the eye cannot see is not a reading, and a battery still
    // holding one per cent is not the same picture as one holding none.
    let width = min(box.width, max(1.2, box.width * figure.fraction))
    let rect = CGRect(x: box.minX, y: box.minY, width: width, height: box.height)
    ctx.addPath(
        CGPath(
            roundedRect: rect,
            cornerWidth: min(options.fillRadius, width / 2),
            cornerHeight: options.fillRadius,
            transform: nil
        )
    )
    ctx.setFillColor(hue)
    ctx.fillPath()
}

/// Draws the accounts left to right IN THE ORDER GIVEN — the panel's order.
///
/// Returns the ink width. Every origin is rounded to a whole point, so the 1 pt walls stay
/// crisp at 1x and at 2x.
@discardableResult
nonisolated func drawStrip(
    _ ctx: CGContext,
    _ cells: [BatteryCell],
    at x0: CGFloat,
    midY: CGFloat,
    _ theme: BatteryTheme,
    _ options: BatteryOptions,
    _ layout: BatteryLayout
) -> CGFloat {
    let body = options.body
    let y = (midY - body.h / 2).rounded()
    var x = x0
    for (index, cell) in cells.enumerated() {
        if index > 0 { x += layout.gap }
        drawBattery(
            ctx,
            cell,
            at: CGPoint(x: x.rounded(), y: y),
            theme,
            options
        )
        x += body.ink
    }
    return x - x0
}

/// The ink a strip of `count` batteries occupies, in points.
nonisolated func batteryStripInkWidth(
    count: Int,
    _ options: BatteryOptions = BatteryOptions(),
    _ layout: BatteryLayout = BatteryLayout()
) -> CGFloat {
    guard count > 0 else { return 0 }
    return CGFloat(count) * options.body.ink + CGFloat(count - 1) * layout.gap
}
