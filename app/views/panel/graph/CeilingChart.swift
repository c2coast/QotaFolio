import Kit
import SwiftUI

/// The Ceiling graph of a week picture: a canvas that works out the geometry at its own size, with
/// its words measured as they will be drawn, and strokes it. It holds no state, and nothing moves.
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
            let ceiling = Ceiling(picture: picture, size: size, words: words) { text, weight in
                context.resolve(Self.text(text, weight)).measure(in: CGSize(width: CGFloat.infinity, height: .infinity))
            }
            draw(ceiling, in: context)
        }
    }

    /// The chart's type: 10 points, with figures of one width, as the app's.
    static func text(_ words: String, _ weight: Weight) -> Text {
        let weight: Font.Weight = switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
        return Text(words).font(.system(size: 10, weight: weight)).monospacedDigit()
    }

    private func draw(_ ceiling: Ceiling, in context: GraphicsContext) {
        for band in ceiling.bands {
            context.fill(Path(band), with: .color(Color(palette.band)))
        }
        for stroke in ceiling.strokes {
            var path = Path()
            for line in stroke.lines { path.addLines(line) }
            let style = StrokeStyle(lineWidth: stroke.width, lineCap: stroke.round ? .round : .butt,
                                    lineJoin: stroke.round ? .round : .miter, dash: stroke.dash.map { CGFloat($0) })
            context.stroke(path, with: .color(Color(palette.colour(stroke.tone)).opacity(stroke.opacity)), style: style)
        }
        for dot in ceiling.dots {
            context.fill(circle(dot.center, dot.radius), with: .color(Color(palette.colour(dot.tone))))
            if dot.ring { context.fill(circle(dot.center, dot.radius * 0.44), with: .color(Color(palette.hole))) }
        }
        for label in ceiling.ticks + ceiling.labels {
            let centre = CGPoint(x: label.box.midX, y: label.box.midY)
            if label.halo { halo(label, at: centre, in: context) }
            var text = context.resolve(Self.text(label.text, label.weight))
            text.shading = .color(Color(palette.colour(label.tone)))
            context.draw(text, at: centre, anchor: .center)
        }
    }

    /// A halo of the hole's colour around the words, so the lines under them do not cut them: the
    /// words drawn eight times, a point and a quarter out, in one layer at the hole's weight.
    private func halo(_ label: Ceiling.Label, at centre: CGPoint, in context: GraphicsContext) {
        var text = context.resolve(Self.text(label.text, label.weight))
        let hole = palette.hole
        text.shading = .color(Color(.sRGB, red: hole.red, green: hole.green, blue: hole.blue))
        var layer = context
        layer.opacity = hole.alpha
        layer.drawLayer { inner in
            for k in 0..<8 {
                let angle = Double(k) * .pi / 4
                inner.draw(text, at: CGPoint(x: centre.x + 1.25 * cos(angle), y: centre.y + 1.25 * sin(angle)), anchor: .center)
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
