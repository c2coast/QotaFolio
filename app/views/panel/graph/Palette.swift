import Foundation
import Kit

/// The graph's colours in one look: light or dark, each plain or with Increase Contrast, and with
/// Reduce Transparency or without.
public struct Palette: Hashable, Sendable {
    public let appearance: Appearance

    public init(_ appearance: Appearance) { self.appearance = appearance }

    /// One colour, its parts from 0 to 1.
    public struct RGBA: Hashable, Sendable {
        public let red, green, blue, alpha: Double

        public init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
            (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
        }
    }

    public func colour(_ tone: Tone) -> RGBA {
        switch tone {
        case .level(let level): rgba(level.colour)
        case .ink: rgba(Tokens.Chart.words)
        case .chartInk: rgba(Tokens.Chart.smallPrint)
        case .ceiling: rgba(Tokens.Chart.ceiling)
        case .rule: rgba(Tokens.Chart.rule)
        case .grid: rgba(Tokens.Chart.grid)
        }
    }

    /// The words that come second: the record's sentence and the caption over the chart.
    public var secondaryInk: RGBA { rgba(Tokens.Chart.secondaryWords) }

    /// What shows through the hole of the week's dot: the plate's own lean, lighter on a light
    /// plate and darker on a dark one.
    public var hole: RGBA { rgba(Tokens.Chart.hole) }

    /// The faint band over a stretch nobody watched.
    public var band: RGBA { rgba(Tokens.Surface.track) }

    /// The card's plate: white at a weight on glass, or a weight of ink with Reduce Transparency.
    public var plate: RGBA { rgba(Tokens.Surface.plateFill) }

    /// The plate's one-point edge, lit at the top and shadowed at the bottom.
    public var plateEdge: (top: RGBA, bottom: RGBA) {
        (rgba(Tokens.Surface.plateEdgeTop), rgba(Tokens.Surface.plateEdgeBottom))
    }

    /// A flat stand-in for the panel's glass, for a picture drawn with no window, where glass and
    /// materials do not render.
    public var standIn: RGBA { rgba(Tokens.Surface.standIn) }

    private func rgba(_ looks: Looks<Colour>) -> RGBA {
        rgba(looks(dark: appearance.dark, increased: appearance.increasedContrast))
    }

    private func rgba(_ looks: Translucent<Colour>) -> RGBA {
        rgba(looks(dark: appearance.dark, increased: appearance.increasedContrast, reduceTransparency: appearance.reduceTransparency))
    }

    private func rgba(_ colour: Colour) -> RGBA {
        let parts = colour.parts(dark: appearance.dark)
        return RGBA(parts.red, parts.green, parts.blue, parts.alpha)
    }
}

/// What the person's Mac is set to, as plain values: a picture drawn with no window cannot read
/// Increase Contrast or Reduce Transparency, so they come in from outside.
public struct Appearance: Hashable, Sendable {
    public var dark: Bool
    public var increasedContrast: Bool
    public var reduceTransparency: Bool

    public init(dark: Bool, increasedContrast: Bool = false, reduceTransparency: Bool = false) {
        self.dark = dark
        self.increasedContrast = increasedContrast
        self.reduceTransparency = reduceTransparency
    }
}
