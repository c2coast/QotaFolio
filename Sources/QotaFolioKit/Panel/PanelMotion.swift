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
