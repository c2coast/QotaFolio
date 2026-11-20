import Kit
import SwiftUI

/// The Ceiling graph of a week picture: a canvas that works out the geometry at its own size and
/// strokes it. It holds no state, and nothing moves.
public struct CeilingChart: View {
    /// The chart's size in the panel: the plot, 360 by 128 points, and the axis's words under it.
    public static let size = CGSize(width: 360, height: 128 + Ceiling.axisBand)

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
        // Every line stops a point short of each word's box, so a word on a line reads whole and
        // whatever lies under the line, plate or band, shows round the word as it is.
        var lines = context
        var open = Path(CGRect(origin: .zero, size: size).insetBy(dx: -8, dy: -8))
        for label in ceiling.labels + ceiling.ticks { open.addRect(label.box.insetBy(dx: -1, dy: 0)) }
        lines.clip(to: open, style: FillStyle(eoFill: true))
        for stroke in ceiling.strokes {
            var path = Path()
            for line in stroke.lines { path.addLines(line) }
            let style = StrokeStyle(lineWidth: stroke.width, lineCap: stroke.round ? .round : .butt,
                                    lineJoin: stroke.round ? .round : .miter, dash: stroke.dash.map { CGFloat($0) })
            lines.stroke(path, with: .color(Color(palette.colour(stroke.tone)).opacity(stroke.opacity)), style: style)
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
/// under it. The card's plate and the rows above the graph are the panel's.
public struct WeekGraph: View {
    let picture: WeekPicture
    let words: TimeWords
    let palette: Palette

    public init(picture: WeekPicture, words: TimeWords, palette: Palette) {
        self.picture = picture
        self.words = words
        self.palette = palette
    }

    public var body: some View {
        let sentences = picture.sentences(in: words)
        VStack(alignment: .leading, spacing: 10) {
            Text("Points used this week · to \(words.day(picture.resets.instant))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(palette.secondaryInk))
            CeilingChart(picture: picture, words: words, palette: palette)
                .frame(width: CeilingChart.size.width, height: CeilingChart.size.height)
            Text("\(Text(sentences.forecast).foregroundStyle(Color(palette.colour(.ink))))\(Text(sentences.record.map { " " + $0 } ?? "").foregroundStyle(Color(palette.secondaryInk)))")
                .font(.system(size: 12))
                .monospacedDigit()
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: CeilingChart.size.width, alignment: .leading)
    }
}

extension Color {
    public init(_ rgba: Palette.RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}
