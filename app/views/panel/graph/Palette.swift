import Foundation

/// The graph's colours in one appearance: light or dark, each plain or with Increase Contrast.
///
/// Every neutral is a weight of black on a light plate and of white on a dark one, so it leans
/// with whatever is under the plate. The numbers are the app's: `PanelTone` for the chart's
/// neutrals and the plate, `LevelPalette` for the three levels. The band and the two inks of the
/// words are the chart page's. A later phase writes this value from one file of design values.
public struct Palette: Hashable, Sendable {
    public let appearance: Appearance

    public init(_ appearance: Appearance) { self.appearance = appearance }

    /// One colour, its parts from 0 to 1.
    public struct RGBA: Hashable, Sendable {
        public let red, green, blue, alpha: Double

        init(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) {
            (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
        }

        init(hex: UInt32) {
            self.init(Double(hex >> 16 & 0xFF) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
    }

    public func colour(_ tone: Tone) -> RGBA {
        switch tone {
        case .level(let level): self.level(level)
        case .ink: weight(light: 0.85, lightIncreased: 0.95, dark: 0.85, darkIncreased: 0.95)
        case .chartInk: weight(light: 0.62, lightIncreased: 0.82, dark: 0.72, darkIncreased: 0.90)
        case .rule: weight(light: 0.30, lightIncreased: 0.45, dark: 0.32, darkIncreased: 0.48)
        case .grid: weight(light: 0.14, lightIncreased: 0.26, dark: 0.14, darkIncreased: 0.28)
        }
    }

    /// The words that come second: the record's sentence and the caption over the chart.
    public var secondaryInk: RGBA { weight(light: 0.50, lightIncreased: 0.70, dark: 0.55, darkIncreased: 0.75) }

    /// What shows through the hole of the week's dot: the plate's own lean, lighter on a light
    /// plate and darker on a dark one.
    public var hole: RGBA {
        appearance.dark ? RGBA(0, 0, 0, appearance.increasedContrast ? 0.72 : 0.60)
                        : RGBA(1, 1, 1, appearance.increasedContrast ? 0.92 : 0.86)
    }

    /// The faint band over a stretch nobody watched.
    public var band: RGBA { weight(light: 0.045, lightIncreased: 0.09, dark: 0.05, darkIncreased: 0.10) }

    /// The card's plate: white at a weight on glass, or a weight of ink with Reduce Transparency.
    public var plate: RGBA {
        let (dark, increased) = (appearance.dark, appearance.increasedContrast)
        if appearance.reduceTransparency { return weight(light: 0.07, lightIncreased: 0.16, dark: 0.07, darkIncreased: 0.16) }
        return RGBA(1, 1, 1, dark ? (increased ? 0.26 : 0.13) : (increased ? 0.72 : 0.42))
    }

    /// The plate's one-point edge, lit at the top and shadowed at the bottom.
    public var plateEdge: (top: RGBA, bottom: RGBA) {
        let (dark, increased) = (appearance.dark, appearance.increasedContrast)
        if appearance.reduceTransparency {
            let edge = weight(light: 0.16, lightIncreased: 0.40, dark: 0.16, darkIncreased: 0.40)
            return (edge, edge)
        }
        return (RGBA(1, 1, 1, dark ? (increased ? 0.45 : 0.20) : (increased ? 0.60 : 0.38)),
                RGBA(0, 0, 0, dark ? (increased ? 0.30 : 0.14) : (increased ? 0.18 : 0.07)))
    }

    /// A flat stand-in for the panel's glass, for a picture drawn with no window, where glass and
    /// materials do not render.
    public var standIn: RGBA { RGBA(hex: appearance.dark ? 0x292929 : 0xEBEBEB) }

    private func level(_ level: Level) -> RGBA {
        let hex: (UInt32, UInt32, UInt32, UInt32) = switch level {
        case .plenty: (0x39955E, 0x1E7C48, 0x59D389, 0x52EC93)
        case .low: (0xA97500, 0x8B6000, 0xEBAA2E, 0xFDBE54)
        case .nearlyGone: (0xB0263A, 0x93142B, 0xF65C69, 0xFB8085)
        }
        return RGBA(hex: pick(hex.0, hex.1, hex.2, hex.3))
    }

    private func weight(light: Double, lightIncreased: Double, dark: Double, darkIncreased: Double) -> RGBA {
        let ink = appearance.dark ? 1.0 : 0.0
        return RGBA(ink, ink, ink, pick(light, lightIncreased, dark, darkIncreased))
    }

    private func pick<T>(_ light: T, _ lightIncreased: T, _ dark: T, _ darkIncreased: T) -> T {
        switch (appearance.dark, appearance.increasedContrast) {
        case (false, false): light
        case (false, true): lightIncreased
        case (true, false): dark
        case (true, true): darkIncreased
        }
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
