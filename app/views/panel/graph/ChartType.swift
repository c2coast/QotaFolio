import Kit
import SwiftUI

/// The chart's words as they are set: the system font in the chart's type roles, with figures of
/// one width, in the weight each word asks for. The geometry measures a word here, and the canvas
/// draws the very line it measured, so a word's box in the geometry is where the word is drawn.
enum ChartType {
    /// A word's width in points.
    static func width(_ text: String, _ weight: Weight) -> Double {
        CTLineGetTypographicBounds(line(text, weight), nil, nil, nil)
    }

    /// Draws a word centred in its box, in the colour the context fills with. The context is the
    /// canvas's, whose y runs down.
    static func draw(_ text: String, _ weight: Weight, centredIn box: CGRect, in cg: CGContext) {
        let line = line(text, weight)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        cg.textPosition = CGPoint(x: box.midX - width / 2, y: box.midY + (ascent - descent) / 2)
        CTLineDraw(line, cg)
    }

    /// The role of a word in the chart, by the weight the geometry gives it.
    private static func role(_ weight: Weight) -> TypeRole {
        switch weight {
        case .regular: Tokens.Typography.axis
        case .medium: Tokens.Typography.axisMedium
        case .semibold: Tokens.Typography.axisStrong
        }
    }

    private static func line(_ text: String, _ weight: Weight) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: role(weight).nsFont, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
    }
}

/// The graph's one place where a type role becomes a font.
extension TypeRole {
    /// The role as SwiftUI sets it.
    var font: Font {
        let font = Font.system(size: size, weight: fontWeight)
        return monospacedDigits ? font.monospacedDigit() : font
    }

    /// The role as AppKit sets it, for a word the canvas measures and draws itself.
    var nsFont: NSFont {
        monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: nsWeight) : .systemFont(ofSize: size, weight: nsWeight)
    }

    private var fontWeight: Font.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }

    private var nsWeight: NSFont.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }
}
