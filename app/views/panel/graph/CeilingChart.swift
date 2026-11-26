import Kit
import SwiftUI

/// The Ceiling graph of a week picture: a canvas that works out the geometry at its own size and
/// strokes it. It holds no state, and nothing moves.
public struct CeilingChart: View {
    /// The chart's size in the panel: the plot, 128 points high and as wide as a card's content,
    /// 360 points, and the axis's words under it.
    public nonisolated static let size = CGSize(
        width: Tokens.Panel.width - 2 * Tokens.Panel.padding - 2 * Tokens.Panel.cardPadding, height: 128 + Ceiling.axisBand)

    let picture: WeekPicture
    let words: TimeWords
    let palette: Palette

    public init(picture: WeekPicture, words: TimeWords, palette: Palette) {
        self.picture = picture
        self.words = words
        self.palette = palette
    }

    public var body: some View {
        Canvas { context, size in
            let ceiling = Ceiling(picture: picture, size: size, words: words)
            draw(ceiling, in: context, size: size)
        }
    }

    private func draw(_ ceiling: Ceiling, in context: GraphicsContext, size: CGSize) {
        for band in ceiling.bands {
            context.fill(Path(band), with: .color(Color(palette.band)))
        }
        // Every line but the record's stops a point short of each word's box, so a word on a line
        // reads whole and whatever lies under the line, plate or band, shows round the word as it
        // is. The record is never cut: no word takes a place on it.
        var lines = context
        var open = Path(CGRect(origin: .zero, size: size).insetBy(dx: -8, dy: -8))
        for label in ceiling.labels + ceiling.ticks { open.addRect(label.box.insetBy(dx: -1, dy: 0)) }
        lines.clip(to: open, style: FillStyle(eoFill: true))
        for stroke in ceiling.strokes {
            var path = Path()
            for line in stroke.lines { path.addLines(line) }
            let style = StrokeStyle(lineWidth: stroke.width, lineCap: stroke.round ? .round : .butt,
                                    lineJoin: stroke.round ? .round : .miter, dash: stroke.dash.map { CGFloat($0) })
            let into = if case .record = stroke.part { context } else { lines }
            into.stroke(path, with: .color(Color(palette.colour(stroke.tone)).opacity(stroke.opacity)), style: style)
        }
        for dot in ceiling.dots {
            context.fill(circle(dot.center, dot.radius), with: .color(Color(palette.colour(dot.tone))))
            if dot.ring { context.fill(circle(dot.center, dot.radius * 0.44), with: .color(Color(palette.hole))) }
        }
        context.withCGContext { cg in
            for label in ceiling.ticks + ceiling.labels {
                let ink = palette.colour(label.tone)
                cg.setFillColor(CGColor(srgbRed: ink.red, green: ink.green, blue: ink.blue, alpha: ink.alpha))
                ChartType.draw(label.text, label.weight, centredIn: label.box, in: cg)
            }
        }
    }

    private func circle(_ centre: CGPoint, _ radius: Double) -> Path {
        Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius))
    }
}

/// The graph's part of the card: the caption over the chart, the chart, and the two sentences
/// under it. The card's plate and the rows above the graph are the panel's. To VoiceOver it is one
/// element, which `SpokenGraph` says.
public struct WeekGraph: View {
    let picture: WeekPicture
    let words: TimeWords
    let palette: Palette
    let width: Double

    /// The width is the chart's, and the words under it wrap to it. The panel's is 360 points.
    public init(picture: WeekPicture, words: TimeWords, palette: Palette, width: Double = CeilingChart.size.width) {
        self.picture = picture
        self.words = words
        self.palette = palette
        self.width = width
    }

    public var body: some View {
        let sentences = picture.sentences(in: words)
        let spoken = SpokenGraph(picture: picture, words: words, size: CGSize(width: width, height: CeilingChart.size.height))
        VStack(alignment: .leading, spacing: 10) {
            Text("Points used this week · to \(words.day(picture.resets.instant))")
                .font(Tokens.Typography.chartTitle.font)
                .foregroundStyle(Color(palette.secondaryInk))
            CeilingChart(picture: picture, words: words, palette: palette)
                .frame(width: width, height: CeilingChart.size.height)
            Text("\(Text(sentences.forecast).foregroundStyle(Color(palette.colour(.ink))))\(Text(sentences.record.map { " " + $0 } ?? "").foregroundStyle(Color(palette.secondaryInk)))")
                .font(Tokens.Typography.bodyFigures.font)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken.name)
        .accessibilityValue(spoken.value)
        .accessibilityCustomContent(AccessibilityCustomContentKey("What the record shows"), spoken.record.map { Text($0) }, importance: .high)
        .accessibilityChartDescriptor(spoken)
    }
}

extension Color {
    public init(_ rgba: Palette.RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}
