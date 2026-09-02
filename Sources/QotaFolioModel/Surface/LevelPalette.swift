import Foundation

/// The colour every surface draws a level in.
///
/// One question decides it: how much of this window is still there. More than half, green; from
/// half down to a fifth, amber; a fifth or less, red. Half a window in hand is the moment pace
/// starts to matter, which is why it is where the colour changes; at a fifth it is nearly gone.
///
/// It is the fuel gauge anyone can already read, and it is the same three steps on the menu-bar
/// battery, on a card's window row, on the widget's ring and on a block in the week — so a
/// glance at any of them is answered the same way. Which provider an account belongs to is
/// written on the card in its name and its mark; the colour is spent on the one thing a battery
/// is for.
///
/// The tones are the app's own, not the system's, and they are derived rather than picked.
///
/// One hue per band, held in every form: green at OKLCH hue 154, amber at 78, red at 19. Then
/// one lightness per appearance, and whatever chroma the sRGB gamut offers at that lightness —
/// which is the inversion that separates a designed status family from three system colours.
/// Fixing the chroma instead and letting the lightness fall out is what leaves green, amber and
/// red at three different lightnesses, each sitting on the gamut wall, none of them a family.
/// Fixing the lightness produces the ranking green < amber < red in chroma for free, and that
/// is the right ranking: the resting state is the quietest thing on the panel and the alarm the
/// loudest. Red alone is pulled back off the wall, because at a shared lightness the gamut
/// hands red about 1.4 times green's chroma and an untouched red out-shouts the other two.
///
/// The lightnesses come from the surfaces these tones are actually drawn on, measured off the
/// app's own screen: a near-white plate in light, a plate that carries the desktop through the
/// glass in dark. The system colours miss those surfaces badly — ten of the twelve were under
/// 3:1 against the track they sit in, and Increase Contrast on dark was the worst of the four.
///
/// They are written out here rather than read from `Color.green` where they are drawn, because
/// the menu-bar strip draws into a bitmap whose polarity and contrast are arguments rather than
/// the process's own appearance — and when the panel is open its cards hang a few points under
/// the batteries, so the two have to be the same colour to the byte.
public nonisolated enum LevelPalette {
    /// Above this share still in hand — half — a level is green.
    public static let plentyAbovePercent = 50

    /// At or below this share, red. The same fifth at which a battery goes low.
    public static let nearlyGoneAtOrBelowPercent = AccountLevel.lowRemainingPercent

    /// The three steps a level is drawn in.
    public enum Band: Hashable, Sendable, CaseIterable {
        /// More than half of it is still there.
        case plenty
        /// Getting low: between a fifth and a half.
        case low
        /// A fifth or less, down to nothing.
        case nearlyGone
    }

    /// The band for a share still in hand, 0…100.
    ///
    /// One boundary rule, and every surface reaches it through the same number:
    /// `remainingPercent(fromUsedPercent:)`. A window row prints what it has used and a battery
    /// draws what it has left, but both land on this step from the same arithmetic, so the bar
    /// on a card and the battery above it can never be two different colours for one window.
    public static func band(remainingPercent: Int) -> Band {
        if remainingPercent <= nearlyGoneAtOrBelowPercent { return .nearlyGone }
        if remainingPercent > plentyAbovePercent { return .plenty }
        return .low
    }

    /// One colour, as sRGB components in 0…1.
    ///
    /// Not a `Color` and not a `CGColor`: this type is read by a SwiftUI card, a WidgetKit ring
    /// and a Core Graphics bitmap, and it belongs to none of them.
    public struct Ink: Hashable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// The same colour written the way the system writes it, `0xRRGGBB` in sRGB.
        public init(hex: UInt32) {
            self.init(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }
    }

    /// The colour a band is drawn in.
    ///
    /// - Parameters:
    ///   - band: which of the three steps.
    ///   - onDark: whether what it is drawn on is dark. For the strip that is the menu bar's own
    ///     effective appearance, which follows the wallpaper; everywhere else it is the colour
    ///     scheme.
    ///   - increasedContrast: Increase Contrast is on, and the deepened variant is wanted.
    public static func ink(_ band: Band, onDark: Bool, increasedContrast: Bool = false) -> Ink {
        tones(band).ink(onDark: onDark, increasedContrast: increasedContrast)
    }

    private static func tones(_ band: Band) -> Tones {
        switch band {
        case .plenty: green
        case .low: amber
        case .nearlyGone: red
        }
    }

    /// One band in the four forms it resolves to.
    private struct Tones {
        let light: Ink
        let lightIncreased: Ink
        let dark: Ink
        let darkIncreased: Ink

        func ink(onDark: Bool, increasedContrast: Bool) -> Ink {
            switch (onDark, increasedContrast) {
            case (false, false): light
            case (false, true): lightIncreased
            case (true, false): dark
            case (true, true): darkIncreased
            }
        }
    }

    /// Green, hue 154 — a step cooler than the system's 147, which is the raw green axis of the
    /// screen itself. Every palette that has been through this question deliberately sits
    /// between 155 and 170, the 1980s safety-colour standard included. Held at eighty per cent
    /// of what the gamut allows: this is the tone the user sees nearly all the time, and it has
    /// no news to deliver.
    private static let green = Tones(
        light: Ink(hex: 0x39955E),
        lightIncreased: Ink(hex: 0x1E7C48),
        dark: Ink(hex: 0x59D389),
        darkIncreased: Ink(hex: 0x52EC93)
    )

    /// Amber, hue 78 — a gold, not an orange. Apple's own three-tier level indicator uses its
    /// yellow here, not its orange; the ambers of considered palettes are either gold at 74–90
    /// or burnt orange at 42–51, and the system's 56 is the gap between them; and the Anthropic
    /// mark on the same card is a terracotta at hue 40, which an orange bar would be mistaken
    /// for. It runs at the gamut's edge because a gold has nowhere else to go.
    private static let amber = Tones(
        light: Ink(hex: 0xA97500),
        lightIncreased: Ink(hex: 0x8B6000),
        dark: Ink(hex: 0xEBAA2E),
        darkIncreased: Ink(hex: 0xFDBE54)
    )

    /// Red, hue 19 — turned from the system's 26 toward crimson. It is the strongest single
    /// thing that can be done for a reader who cannot separate red from green, and it puts
    /// twenty-one degrees between the alarm and the terracotta mark. Pulled back to about ninety
    /// per cent of the gamut: at a shared lightness red reaches half again the chroma green can,
    /// and left alone it drowns the other two.
    private static let red = Tones(
        light: Ink(hex: 0xB0263A),
        lightIncreased: Ink(hex: 0x93142B),
        dark: Ink(hex: 0xF65C69),
        darkIncreased: Ink(hex: 0xFB8085)
    )
}
