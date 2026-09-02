import QotaFolioModel
import SwiftUI

/// One account as a ring: the menu-bar battery bent into a circle, because a ring is Apple's own
/// shape for a battery in a small square.
///
/// It draws the same one quantity the batteries are drawn to — this session's own share or the
/// week's, whichever the person chose in Settings — as the filled arc, in that quantity's own
/// colour, and prints the very same number in the middle. One figure, said twice, so the arc and
/// the number can never be read as two different answers.
///
/// Compiled into the widget extension and the app (Spotlight's answer draws it too). It reads
/// only Model types. Under accented rendering the arc is the accent group and the track the
/// primary group, so the hierarchy survives a single tint.
struct QuotaRing: View {
    let level: AccountLevel
    /// Which quantity the strip is drawn to, and therefore this ring.
    let showing: StripShows
    let diameter: CGFloat
    let showsNumber: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let lineWidth = max(3, diameter * 0.11)
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
            if level.hasReading {
                // Nothing left still draws the smallest arc the shape allows — the ring's own
                // form of the battery's residual hairline, in the colour a level runs out in.
                Circle()
                    .trim(from: 0, to: max(0.012, figure.fraction))
                    .stroke(hue, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .widgetAccentableIfAvailable()
            }
            if showsNumber {
                numberLabel
                    .font(.system(size: max(9, diameter * 0.26), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .padding(lineWidth + 2)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// The length and the verdict, from the model's own rule — the one the menu-bar battery and
    /// the Control's symbol read too.
    private var figure: StripFigure {
        StripFigure(
            showing: showing,
            weeklyRemainingPercent: level.weeklyRemainingPercent,
            sessionRemainingPercent: level.sessionRemainingPercent
        )
    }

    @ViewBuilder private var numberLabel: some View {
        if !level.hasReading {
            Text(verbatim: "—").foregroundStyle(.secondary)
        } else if figure.isSpent {
            Text(verbatim: "0%").foregroundStyle(hue)
        } else {
            Text(verbatim: "\(figure.remainingPercent)%")
        }
    }

    /// The level's colour: green while more than half of the drawn window is there, amber as it
    /// gets low, red at a fifth or less — the same three steps the menu-bar battery is drawn in,
    /// read off the same number this ring prints in its middle.
    private var hue: Color {
        colour(LevelPalette.band(remainingPercent: figure.remainingPercent))
    }

    private func colour(_ band: LevelPalette.Band) -> Color {
        swiftUI(LevelPalette.ink(band, onDark: dark, increasedContrast: increased))
    }

    private func swiftUI(_ ink: LevelPalette.Ink) -> Color {
        Color(.sRGB, red: ink.red, green: ink.green, blue: ink.blue)
    }

    private var dark: Bool { colorScheme == .dark }
    private var increased: Bool { colorSchemeContrast == .increased }

    private var trackColor: Color {
        Color.primary.opacity(level.hasReading ? 0.10 : 0.22)
    }
}

private extension View {
    /// `widgetAccentable()` is WidgetKit's; the app compiles this file too, where the modifier
    /// is a no-op because there is no widget rendering mode to speak of.
    @ViewBuilder func widgetAccentableIfAvailable() -> some View {
        #if canImport(WidgetKit)
        self.widgetAccentable()
        #else
        self
        #endif
    }
}

#if canImport(WidgetKit)
import WidgetKit
#endif
