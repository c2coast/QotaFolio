import SwiftUI
import QotaFolioCore

/// One window, one level row.
///
/// The row is the core, twice over: the number and its picture. Line one is three columns —
/// the window's name, the percentage used (right-aligned, so the digits stack down the
/// panel), and the reset at the trailing edge. Line two is the bar at the row's full width.
/// Nothing on it predicts.
///
/// Hidden from VoiceOver as a whole: the card speaks every row in its one sentence, and a
/// VoiceOver user should not have to walk three rows to hear an account.
struct WindowRow: View {
    let level: UsageWindowLevel
    let tone: PanelTone

    @Environment(\.panelNow) private var panelNow
    @Environment(\.sentenceStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(level.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .frame(width: PanelMetrics.nameColumn, alignment: .leading)
                Text(PanelWords.percent(level.wholePercentUsed, style: style))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(width: PanelMetrics.percentColumn, alignment: .trailing)
                Text(qfLocalized("face.used", defaultValue: "used", comment: "The word after a window's percentage on the panel: 38% used."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                Spacer(minLength: 8)
                if let resetsAt = level.resetsAt {
                    ResetLabel(resetsAt: resetsAt, now: panelNow ?? .now, style: style)
                }
            }
            LevelBar(
                usedPercent: level.usedPercent,
                tint: tone.level(level.usedPercent),
                atRest: level.isSpent,
                tone: tone
            )
            .frame(height: PanelMetrics.barHeight)
        }
        .accessibilityHidden(true)
    }
}

/// The countdown beside an absolute time. The panel's one clock drives it.
struct ResetLabel: View {
    let resetsAt: Date
    let now: Date
    let style: SentenceStyle

    var body: some View {
        let countdown = ResetCountdown.make(
            resetsAt: resetsAt,
            now: now,
            locale: style.locale,
            calendar: style.calendar,
            timeZone: style.timeZone
        )
        HStack(spacing: 4) {
            Text(PanelWords.dayAndClock(resetsAt, now: now, style: style))
                .foregroundStyle(.tertiary)
            Text("·")
                .foregroundStyle(.quaternary)
            Text(countdown.visible)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(countsDown: true))
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// The level: what is spent of this window, and nothing else.
///
/// The fill is the level's own colour on a neutral track — green under two thirds used, amber
/// up to four fifths, red past it — square where it starts, rounded where the data ends, the track's
/// own capsule closing both ends. A spent window sits back, complete. The fill and the printed
/// percentage are literally the same number, so the state never rides on colour alone. Minimum
/// fill width is the bar's height, so one percent is a dot and not a sliver.
struct LevelBar: View {
    let usedPercent: Double
    let tint: Color
    /// Spent sits back: there is no decision to make about a window until it returns.
    let atRest: Bool
    let tone: PanelTone

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack(alignment: .leading) {
                Capsule().fill(tone.track)
                if usedPercent > 0 {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: height / 2,
                        topTrailingRadius: height / 2,
                        style: .continuous
                    )
                    .fill(tint.opacity(atRest ? tone.spent : 1.0))
                    .frame(width: max(height, width * min(usedPercent, 100) / 100))
                }
            }
            .clipShape(Capsule())
            .animation(
                reduceMotion ? .easeInOut(duration: PanelMotion.reducedDuration) : .smooth(duration: 0.6),
                value: usedPercent
            )
        }
        .accessibilityHidden(true)
    }
}
