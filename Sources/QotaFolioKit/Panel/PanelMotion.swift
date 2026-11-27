import Kit
import SwiftUI

public nonisolated enum PanelMotion {
    /// The card's animation, and nothing at all for someone who has asked for less movement.
    public static func card(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Tokens.Motion.card.animation
    }

    public static let dissolve: Animation = Tokens.Motion.dissolve.animation

    static let hover: Animation = Tokens.Motion.hover.animation
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
