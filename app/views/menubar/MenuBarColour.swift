import CoreGraphics
import Kit

/// The menu bar's turning of a design colour: the strip is drawn in Core Graphics, in the look of
/// the bar it sits on.
extension Colour {
    nonisolated func cgColor(darkBar: Bool) -> CGColor {
        let parts = self.parts(dark: darkBar)
        return CGColor(red: parts.red, green: parts.green, blue: parts.blue, alpha: parts.alpha)
    }
}
