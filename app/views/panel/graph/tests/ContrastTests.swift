import Foundation
import Graph
import Testing

/// The graph's contrast, measured from its colours as they are drawn: each colour laid over the
/// card's plate, which lies over the flat stand-in for the panel's glass, and over the band on
/// that plate, by WCAG 2's relative luminance. In every look: light and dark, each plain and with
/// Increase Contrast, each with Reduce Transparency or without.
@Suite("The graph's contrast in every look")
struct ContrastTests {
    static let looks: [Appearance] = [false, true].flatMap { dark in
        [false, true].flatMap { increased in
            [false, true].map { Appearance(dark: dark, increasedContrast: increased, reduceTransparency: $0) }
        }
    }

    /// What lies behind a mark: the plate, and the band over the plate.
    static func behind(_ palette: Palette) -> [Palette.RGBA] {
        let plate = over(palette.plate, palette.standIn)
        return [plate, over(palette.band, plate)]
    }

    /// The least contrast of a colour against each thing behind it.
    static func contrast(_ colour: Palette.RGBA, on backgrounds: [Palette.RGBA]) -> Double {
        backgrounds.map { ratio(over(colour, $0), $0) }.min()!
    }

    @Test("The ceiling's line reaches 3 to 1, as a line that carries meaning must", arguments: looks)
    func ceiling(_ look: Appearance) {
        let palette = Palette(look)
        let measured = Self.contrast(palette.colour(.ceiling), on: Self.behind(palette))
        #expect(measured >= 3, "\(look): \(measured)")
    }

    /// The words in the plot and under it are in chart ink, or in ink when they matter most; the
    /// sentences in ink and secondary ink; the caption in secondary ink.
    @Test("Every word reaches 4.5 to 1 against what is behind it", arguments: looks)
    func words(_ look: Appearance) {
        let palette = Palette(look)
        for (name, ink) in [("chart ink", palette.colour(.chartInk)), ("ink", palette.colour(.ink)), ("secondary ink", palette.secondaryInk)] {
            let measured = Self.contrast(ink, on: Self.behind(palette))
            #expect(measured >= 4.5, "\(look): \(name) \(measured)")
        }
    }
}

/// A colour laid over an opaque one.
func over(_ top: Palette.RGBA, _ under: Palette.RGBA) -> Palette.RGBA {
    let a = top.alpha
    return Palette.RGBA(top.red * a + under.red * (1 - a), top.green * a + under.green * (1 - a), top.blue * a + under.blue * (1 - a))
}

/// WCAG 2's contrast ratio of two opaque colours.
func ratio(_ a: Palette.RGBA, _ b: Palette.RGBA) -> Double {
    func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    func luminance(_ c: Palette.RGBA) -> Double { 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue) }
    let (x, y) = (luminance(a), luminance(b))
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}
