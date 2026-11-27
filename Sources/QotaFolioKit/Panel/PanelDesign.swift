import CoreGraphics
import Kit
import SwiftUI

extension Colour {
    nonisolated func cgColor(darkBar: Bool) -> CGColor {
        let parts = self.parts(dark: darkBar)
        return CGColor(red: parts.red, green: parts.green, blue: parts.blue, alpha: parts.alpha)
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
