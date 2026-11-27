import CoreGraphics
import Kit
import SwiftUI

extension Colour {
    nonisolated func color(lift: Double = 0) -> Color {
        switch self {
        case .srgb:
            let parts = self.parts(dark: false)
            return Color(.sRGB, red: parts.red, green: parts.green, blue: parts.blue)
        case .black(let weight): return Color.black.opacity(weight + lift)
        case .white(let weight): return Color.white.opacity(weight + lift)
        case .ink(let weight): return Color.primary.opacity(weight + lift)
        case .grey(let grey, let weight): return Color(white: grey).opacity(weight + lift)
        }
    }

    nonisolated func cgColor(darkBar: Bool) -> CGColor {
        let parts = self.parts(dark: darkBar)
        return CGColor(red: parts.red, green: parts.green, blue: parts.blue, alpha: parts.alpha)
    }
}

nonisolated enum PanelType {
    static let title = font(Tokens.Typography.title)
    static let label = font(Tokens.Typography.label)
    static let figure = font(Tokens.Typography.figure)
    static let body = font(Tokens.Typography.body)
    static let bodyFigures = font(Tokens.Typography.bodyFigures)
    static let note = font(Tokens.Typography.note)
    static let caption = font(Tokens.Typography.caption)
    static let captionFigures = font(Tokens.Typography.captionFigures)
    static let glyph = font(Tokens.Typography.glyph)
    static let advisoryGlyph = font(Tokens.Typography.advisoryGlyph)
    static let aboutGlyph = font(Tokens.Typography.aboutGlyph)

    private static func font(_ role: TypeRole) -> Font {
        let weight: Font.Weight = switch role.weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
        let font = Font.system(size: role.size, weight: weight)
        return role.monospacedDigits ? font.monospacedDigit() : font
    }
}

extension Timing {
    nonisolated var animation: Animation {
        switch curve {
        case .smooth: .smooth(duration: duration)
        case .easeOut: .easeOut(duration: duration)
        case .easeInOut: .easeInOut(duration: duration)
        }
    }
}
