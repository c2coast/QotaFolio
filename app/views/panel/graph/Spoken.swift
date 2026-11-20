import Kit
import SwiftUI

/// What the graph says to a person who cannot see it. The graph's part of the card is one element:
/// its name is the caption's words, and its value is the forecast's sentence. It also offers
/// VoiceOver's audio graph the lines it draws, read from the geometry, with the record's sentence
/// as the chart's summary.
///
/// The audio graph's time axis runs in the chart's own points, folds and all, so it plays the week
/// as it is drawn. Each place says the clock time there, and a place inside a fold says the
/// stretch the fold holds.
public struct SpokenGraph: AXChartDescriptorRepresentable, Sendable {
    public let name: String
    public let value: String
    let summary: String?
    let ceiling: Ceiling
    let words: TimeWords

    public init(picture: WeekPicture, words: TimeWords, size: CGSize) {
        let sentences = picture.sentences(in: words)
        name = "Points used this week, to \(words.day(picture.resets.instant))"
        value = sentences.forecast
        summary = sentences.record
        ceiling = Ceiling(picture: picture, size: size, words: words)
        self.words = words
    }

    /// What the time axis says at a place, in the chart's points from the left.
    public func time(at x: Double) -> String {
        let axis = ceiling.axis
        if let fold = axis.pieces.first(where: { $0.fold != nil && x > $0.x0 && x < $0.x1 }) {
            return "\(words.day(fold.from)) to \(words.day(fold.to))"
        }
        return words.day(axis.time(at: x))
    }

    public func makeChartDescriptor() -> AXChartDescriptor {
        let time = AXNumericDataAxisDescriptor(title: "Time", range: 0...ceiling.plot.width, gridlinePositions: []) { time(at: $0) }
        let points = AXNumericDataAxisDescriptor(title: "Points of the week", range: 0...ceiling.top, gridlinePositions: []) {
            "\(Int($0.rounded())) points"
        }
        return AXChartDescriptor(title: name, summary: summary, xAxis: time, yAxis: points, series: series())
    }

    public func updateChartDescriptor(_ descriptor: AXChartDescriptor) {}

    /// For each limit, what was used, its ceiling and its forecast: the lines the graph draws, in
    /// the order a reader meets them, each with its points from left to right.
    func series() -> [AXDataSeriesDescriptor] {
        let h = ceiling.plot.height
        let kinds = Set(ceiling.strokes.compactMap(\.part.kind)).sorted { ($0.model ?? "") < ($1.model ?? "") }
        return kinds.flatMap { kind in
            let name = kind.model ?? "Weekly"
            return [("\(name) use", Ceiling.Stroke.Part.record(kind)), ("\(name) limit", .ceiling(kind)), ("\(name) forecast", .forecast(kind))]
                .compactMap { title, part -> AXDataSeriesDescriptor? in
                    let drawn = ceiling.strokes.filter { $0.part == part }.flatMap { $0.lines.joined() }
                    guard !drawn.isEmpty else { return nil }
                    var seen = Set<[Double]>()
                    let ordered = drawn.enumerated().sorted { ($0.element.x, $0.offset) < ($1.element.x, $1.offset) }
                        .map(\.element).filter { seen.insert([$0.x, $0.y]).inserted }
                    return AXDataSeriesDescriptor(name: title, isContinuous: true, dataPoints: ordered.map {
                        AXDataPoint(x: $0.x, y: (h - $0.y) / h * ceiling.top)
                    })
                }
        }
    }
}

extension Ceiling.Stroke.Part {
    /// The limit a line belongs to, for a record, a ceiling or a forecast.
    var kind: Limit.Kind? {
        switch self {
        case .record(let kind), .ceiling(let kind), .forecast(let kind): kind
        case .grid, .baseline, .now, .limitStretch, .foldBreak: nil
        }
    }
}
