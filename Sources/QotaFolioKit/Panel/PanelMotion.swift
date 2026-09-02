import SwiftUI

/// The panel's one motion.
///
/// A card opens and closes on this curve — the whole slab travels, cards, glass and edge together.
/// Both directions read the same number, which is what makes them mirror images of each other.
public nonisolated enum PanelMotion {
    /// A card opening, and a card closing.
    ///
    /// The panel's edge travels about 110 points, and macOS resizes a window that far in about two
    /// tenths of a second; this arrives at nine tenths of the distance in 0.19 s and then eases the
    /// rest. Gentleness is the curve's — a spring with no bounce never snaps — so the length does
    /// not have to supply it, and a motion that runs on every click should not.
    public static let duration: Double = 0.30

    /// How long a change takes for someone who has asked for less movement.
    public static let reducedDuration: Double = 0.2

    /// The card's animation, and nothing at all for someone who has asked for less movement.
    ///
    /// The panel then arrives at its new height in one frame and the instrument dissolves into it
    /// (`dissolve`). That is what Reduce Motion asks for where a change carries meaning: not the
    /// same travel made quicker — a quarter of a second to cross 110 points is faster travel, not
    /// less of it — but a form of the change with no travel in it.
    public static func card(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: duration)
    }

    /// How the instrument arrives when nothing may travel.
    public static let dissolve: Animation = .easeInOut(duration: reducedDuration)
}
