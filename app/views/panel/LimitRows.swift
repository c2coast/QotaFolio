import Graph
import Kit
import SwiftUI

/// The limits of one account at rest, one row each, as Kit says them: the limit's name, how much of
/// it is used over a bar in its level's colour, its reset with its day, and under the bar the
/// verdict in a few words, so the card says whether each limit lasts without a tap. A limit whose
/// reset has passed says so over an empty bar.
///
/// The card speaks every row in its one sentence, from each row's `spoken`, so the rows are hidden
/// from VoiceOver.
struct LimitRows: View {
    let rows: [AccountNow.Row]

    init(rows: [AccountNow.Row]) {
        self.rows = rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(rows, id: \.limit) { LimitRow(row: $0) }
        }
        .accessibilityHidden(true)
    }
}

/// One limit: three columns over its bar, the name, the percent used and the reset, and the verdict
/// under the bar where the bar's own reading ends.
struct LimitRow: View {
    let row: AccountNow.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(row.title)
                    .font(Tokens.Typography.label.font)
                    .lineLimit(1)
                    .frame(width: Tokens.Panel.nameColumn, alignment: .leading)
                switch row.state {
                case .read(let read):
                    Text(read.percent)
                        .font(Tokens.Typography.figure.font)
                        .contentTransition(.numericText())
                        .frame(width: Tokens.Panel.percentColumn, alignment: .trailing)
                    Text("used")
                        .font(Tokens.Typography.body.font)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    Spacer(minLength: 8)
                    if let resets = read.resets { small(resets).foregroundStyle(.tertiary) }
                case .reset(_, let words):
                    Spacer(minLength: 8)
                    small(words).foregroundStyle(.secondary)
                }
            }
            switch row.state {
            case .read(let read):
                LevelBar(used: read.used.value, level: read.level)
                    .frame(height: Tokens.Panel.barHeight)
                    .padding(.top, 1)
                if let verdict = read.verdict {
                    small(verdict).foregroundStyle(.secondary)
                }
            case .reset:
                LevelBar(used: 0, level: .plenty)
                    .frame(height: Tokens.Panel.barHeight)
                    .padding(.top, 1)
            }
        }
    }

    private func small(_ words: String) -> Text {
        Text(words).font(Tokens.Typography.captionFigures.font)
    }
}

/// What is used of a limit, and nothing else: the fill in the level's colour in a recess of the
/// plate, square where it starts and round where the reading ends. A spent limit sits back. The
/// fill and the printed percent are the same number, so the level never rides on colour alone, and
/// the least fill is the bar's height, so one percent is a dot and not a sliver.
struct LevelBar: View {
    let used: Double
    let level: Level

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dark = scheme == .dark, increased = contrast == .increased
        let spent = Whole.left(used) == 0
        GeometryReader { geometry in
            let (width, height) = (geometry.size.width, geometry.size.height)
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.Surface.track(dark: dark, increased: increased).color(dark: dark))
                if used > 0 {
                    UnevenRoundedRectangle(bottomTrailingRadius: height / 2, topTrailingRadius: height / 2, style: .continuous)
                        .fill(level.colour(dark: dark, increased: increased).color(dark: dark)
                            .opacity(spent ? Tokens.Surface.spent(dark: dark, increased: increased) : 1))
                        .frame(width: max(height, width * min(used, 100) / 100))
                }
            }
            .clipShape(Capsule())
            .animation(reduceMotion ? Tokens.Motion.dissolve.animation : .smooth(duration: 0.6), value: used)
        }
        .accessibilityHidden(true)
    }
}
