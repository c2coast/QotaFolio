import Kit
import SwiftUI

/// The panel's motions, design values each, with their reasons in `design/tokens.json`.
///
/// A card opens and closes on one curve: the whole slab travels, cards, glass and edge together.
/// Both directions read the same value, which is what makes them mirror images of each other.
public nonisolated enum PanelMotion {
    /// The card's animation, and nothing at all for someone who has asked for less movement.
    ///
    /// The panel then arrives at its new height in one frame and the instrument dissolves into it
    /// (`dissolve`). That is what Reduce Motion asks for where a change carries meaning: not the
    /// same travel made quicker, but a form of the change with no travel in it.
    public static func card(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Tokens.Motion.card.animation
    }

    /// How a change arrives when nothing may travel.
    public static let dissolve: Animation = Tokens.Motion.dissolve.animation

    /// A hovered plate or control lifting or washing in.
    static let hover: Animation = Tokens.Motion.hover.animation
}
