import SwiftUI

/// The chart's words as they are set: the system font at 10 points, with figures of one width, in
/// the weight each word asks for. The geometry measures a word here, and the canvas draws the very
/// line it measured, so a word's box in the geometry is where the word is drawn.
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

    private static func line(_ text: String, _ weight: Weight) -> CTLine {
        let weight: NSFont.Weight = switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: weight)
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
    }
}
