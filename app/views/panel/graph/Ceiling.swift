import Foundation
import Kit

/// The Ceiling graph of one week picture at one size: everything to be drawn, in the chart's own
/// points, with no colour and no font. The view strokes it; the tests read it.
///
/// The line is the work done this week, which never falls. What the account can hold is a ceiling
/// that steps up when a banked reset gives points back. The model's week sits on the same scale at
/// half a point for each of its points, under its own ceiling. The forecast runs on until it
/// meets its ceiling.
///
/// The chart is the plot and, under it, a band of 18 points for the axis's words.
public struct Ceiling: Sendable {
    public static let axisBand = 18.0

    /// The plot's size. Its top left is the chart's top left.
    public let plot: CGSize
    public let axis: TimeAxis
    /// The unwatched stretches that hid something, and the unrecorded lead-in.
    public let bands: [CGRect]
    /// Every line, in the order it is drawn.
    public let strokes: [Stroke]
    public let dots: [Dot]
    /// The words inside the plot, each in its own box. No two boxes overlap, and every line stops
    /// short of a box, so a word that sits on a line reads whole.
    public let labels: [Label]
    /// The words under the plot: days, hours and the reset's time.
    public let ticks: [Label]

    public struct Stroke: Sendable {
        public let part: Part
        /// Each line is drawn on its own, through its points in order.
        public let lines: [[CGPoint]]
        public let width: Double
        /// Dash and gap lengths; empty for a solid line.
        public let dash: [Double]
        public let tone: Tone
        public let opacity: Double
        /// Round ends and joins, as the record and the forecast have.
        public let round: Bool

        public enum Part: Hashable, Sendable {
            case grid, baseline, now
            /// The red strip under a fold that was spent at the limit.
            case limitStretch
            /// The two slashes that mark a fold's edge.
            case foldBreak
            case ceiling(Limit.Kind)
            case record(Limit.Kind)
            case forecast(Limit.Kind)
        }
    }

    public struct Dot: Sendable {
        public let center: CGPoint
        public let radius: Double
        public let tone: Tone
        /// A ring: the dot has a hole in the chart's hole colour, as the week's now has.
        public let ring: Bool
    }

    public struct Label: Sendable {
        public let kind: Kind
        public let text: String
        public let weight: Weight
        public let tone: Tone
        /// The words sit centred in the box, which holds them with a point to spare.
        public let box: CGRect

        public enum Kind: Hashable, Sendable {
            /// Where a limit's forecast ends: when it runs out, or what it leaves at the reset.
            case forecast(Limit.Kind)
            /// The name of a limit's ceiling.
            case limit(Limit.Kind)
            /// What a banked reset gave back, at its step in the week's ceiling.
            case reset
            case unwatched, unrecorded
            /// A day or an hour under the plot.
            case tick
            /// The reset's time, at the right edge after a fold.
            case resetTime
        }
    }

    public init(picture: WeekPicture, size: CGSize, words: TimeWords) {
        let w = size.width, h = size.height - Self.axisBand
        let axis = TimeAxis(picture: picture, width: w)
        let x = axis.x
        let model = picture.model, now = picture.now
        let reset = picture.resets.instant
        let name = model?.model ?? ""

        let weekCeiling = { (q: WeekPicture.Point) in 100 + q.week.givenBack }
        let modelCeiling = { (q: WeekPicture.Point) in 50 + (q.model?.givenBack ?? 0) / 2 }
        let modelWork = { (q: WeekPicture.Point) in (q.model?.work ?? 0) / 2 }
        let top = max(100, weekCeiling(now)) * 1.18
        let y = { (value: Double) in h - value / top * h }
        let at = { (t: Date, value: Double) in CGPoint(x: x(t), y: y(value)) }

        var strokes: [Stroke] = []
        func stroke(_ part: Stroke.Part, _ lines: [[CGPoint]], _ width: Double, _ tone: Tone,
                    dash: [Double] = [], opacity: Double = 1, round: Bool = false) {
            let lines = lines.filter { $0.count > 1 }
            if !lines.isEmpty { strokes.append(Stroke(part: part, lines: lines, width: width, dash: dash, tone: tone, opacity: opacity, round: round)) }
        }

        // The stretches nobody watched, when something moved in them, and the unrecorded lead-in.
        var bands: [CGRect] = []
        var bandNames: [(center: Double, kind: Label.Kind)] = []
        var spans = picture.gaps
            .filter { gap in
                gap.fall != nil || abs(gap.after.week.work - gap.before.week.work) >= 1
                    || abs((gap.after.model?.work ?? 0) - (gap.before.model?.work ?? 0)) >= 2
            }
            .map { (from: $0.before.at, to: $0.after.at, kind: Label.Kind.unwatched) }
        if let lead = picture.unrecorded { spans.append((lead.start, lead.end, .unrecorded)) }
        for span in spans {
            let a = x(span.from), b = x(span.to)
            bands.append(CGRect(x: a, y: 0, width: b - a, height: h))
            if b - a >= 46 && span.to.timeIntervalSince(span.from) >= 5 * hour { bandNames.append(((a + b) / 2, span.kind)) }
        }

        let ticks = Ticks(axis: axis, picture: picture, words: words, width: w, height: h)
        strokes += ticks.strokes
        stroke(.baseline, [[CGPoint(x: 0, y: h), CGPoint(x: w, y: h)]], 1, .grid)

        // The ceilings: flat, stepping up at a banked reset, and a dotted ramp when the reset fell
        // inside a gap. Known to the reset, so drawn to the right edge.
        func ceiling(_ kind: Limit.Kind, _ value: (WeekPicture.Point) -> Double) {
            var lines = [[CGPoint(x: 0, y: y(value(picture.points[0])))]]
            var ramps: [[CGPoint]] = []
            for (a, b) in zip(picture.points, picture.points.dropFirst()) where value(b) != value(a) {
                if b.at.timeIntervalSince(a.at) > gapSeconds {
                    lines[lines.count - 1].append(at(a.at, value(a)))
                    lines.append([at(b.at, value(b))])
                    ramps.append([at(a.at, value(a)), at(b.at, value(b))])
                } else {
                    lines[lines.count - 1] += [at(b.at, value(a)), at(b.at, value(b))]
                }
            }
            lines[lines.count - 1].append(CGPoint(x: w, y: y(value(now))))
            stroke(.ceiling(kind), lines, 1, .ceiling)
            stroke(.ceiling(kind), ramps, 1, .ceiling, dash: [1, 3])
        }
        if let model { ceiling(model, modelCeiling) }
        ceiling(.week, weekCeiling)
        stroke(.now, [[CGPoint(x: x(now.at), y: 0), CGPoint(x: x(now.at), y: h)]], 1, .rule, dash: [1, 2])

        // The record: solid where watched, dotted across a gap.
        func record(_ kind: Limit.Kind, _ value: (WeekPicture.Point) -> Double, _ width: Double, _ tone: Tone, _ opacity: Double) {
            var solid: [[CGPoint]] = [], dotted: [[CGPoint]] = []
            for (a, b) in zip(picture.points, picture.points.dropFirst()) {
                let p = at(a.at, value(a)), q = at(b.at, value(b))
                if b.at.timeIntervalSince(a.at) > gapSeconds { dotted.append([p, q]) }
                else if let end = solid.last?.last, end == p { solid[solid.count - 1].append(q) }
                else { solid.append([p, q]) }
            }
            stroke(.record(kind), dotted, max(1.25, width - 0.5), tone, dash: [1, 3.5], opacity: opacity, round: true)
            stroke(.record(kind), solid, width, tone, opacity: opacity, round: true)
        }
        let modelTone = Tone.level(Level(used: now.model?.used ?? 0)), weekTone = Tone.level(Level(used: now.week.used))
        if let model { record(model, modelWork, 1.5, modelTone, picture.spent ? 0.45 : 1) }
        record(.week, { $0.week.work }, 2, weekTone, 1)

        // The forecast, on until it meets its ceiling. Nothing runs on the model once the week is
        // spent, so when the week runs out first the model's line stops there, with no label.
        let weekVerdict = picture.verdicts[.week], modelVerdict = model.flatMap { picture.verdicts[$0] }
        let weekOut = weekVerdict?.runsOutAt
        let modelOut = picture.modelSpent ? nil : modelVerdict?.runsOutAt
        let first: Limit.Kind? = if let weekOut, modelOut.map({ weekOut <= $0 }) ?? true { .week } else if modelOut != nil { model } else { nil }
        let red = Tone.level(.nearlyGone)
        var dots: [Dot] = []
        var ends: [(point: CGPoint, name: String, said: String, strong: Bool, kind: Limit.Kind)] = []
        let nowWeek = now.week.work, nowModel = modelWork(now)
        // What a forecast's end says: the time it runs out, or what it leaves at the reset.
        func said(_ path: (out: Date?, rate: Double, landing: Double)) -> String {
            path.out.map(words.quarterDay) ?? "~\(left(path.landing))% left"
        }
        if !picture.spent {
            if let model, !picture.modelSpent, let path = modelVerdict?.path {
                if first == .week, let weekOut {
                    let end = at(weekOut, nowModel + path.rate / 2 * weekOut.timeIntervalSince(now.at) / hour)
                    stroke(.forecast(model), [[at(now.at, nowModel), end]], 1.25, .chartInk, dash: [3, 3], round: true)
                } else {
                    let end = path.out ?? reset
                    let value = path.out != nil ? modelCeiling(now) : nowModel + (path.landing - (now.model?.used ?? 0)) / 2
                    let tone = first == model ? red : .chartInk
                    let point = at(end, value)
                    stroke(.forecast(model), [[at(now.at, nowModel), point]], 1.25, tone, dash: [3, 3], round: true)
                    dots.append(Dot(center: point, radius: 2.5, tone: tone, ring: false))
                    ends.append((point, name, said(path), first == model, model))
                }
            }
            if let path = weekVerdict?.path {
                let end = path.out ?? reset
                let value = path.out != nil ? weekCeiling(now) : nowWeek + (path.landing - now.week.used)
                let tone = first == .week ? red : .chartInk
                let point = at(end, value)
                stroke(.forecast(.week), [[at(now.at, nowWeek), point]], 1.5, tone, dash: [3, 3], round: true)
                dots.append(Dot(center: point, radius: 3, tone: tone, ring: false))
                ends.append((point, "Weekly", said(path), first == .week, .week))
            }
        }
        if model != nil { dots.append(Dot(center: at(now.at, nowModel), radius: 2.5, tone: modelTone, ring: false)) }
        dots.append(Dot(center: at(now.at, nowWeek), radius: 4.5, tone: weekTone, ring: true))

        // The words, each in the first of its places that touches nothing placed before it. A word
        // with no free place is left out: the sentence under the graph says everything it says.
        var placer = Placer(width: w, height: h)
        placer.dot(at(now.at, nowWeek), 6)
        if model != nil { placer.dot(at(now.at, nowModel), 4) }
        let ordered = ends.filter(\.strong) + ends.filter { !$0.strong }
        for end in ordered { placer.dot(end.point, 4) }
        for end in ordered {
            // "Weekly · Wed 19:15", or the time alone where the name leaves it no room: the dot
            // sits on the limit's named ceiling.
            let text = end.said.hasPrefix("~") ? "\(end.name) \(end.said)" : "\(end.name) · \(end.said)"
            placer.put(text, or: end.said, .forecast(end.kind), end.strong ? .semibold : .medium, end.strong ? .ink : .chartInk,
                       around(end.point))
        }
        for (kind, value, text) in [(Limit.Kind.week, weekCeiling, "Weekly limit")] + (model.map { [($0, modelCeiling, "\(name) limit")] } ?? []) {
            let yr = y(value(now)), y0 = y(value(picture.points[0]))
            placer.put(text, .limit(kind), .regular, .chartInk, [
                Placer.Spot(w - 2, yr - 4, .end), Placer.Spot(3, y0 - 4, .start),
                Placer.Spot(w - 2, yr + 11, .end), Placer.Spot(3, y0 + 11, .start),
            ])
        }
        // When the steps of several banked resets crowd, the largest keep their words: a step's
        // height says what it gave back, and the smallest step says least without them.
        let largestFirst = picture.falls.enumerated().sorted { a, b in
            let (x, y) = (a.element.givenBack[.week] ?? 0, b.element.givenBack[.week] ?? 0)
            return x != y ? x > y : a.offset < b.offset
        }
        for (_, fall) in largestFirst {
            guard let q = picture.points.first(where: { $0.at == fall.after.at }) else { continue }
            let back = fall.givenBack[.week] ?? 0
            let xs = x(q.at), yNew = y(weekCeiling(q)), yOld = y(weekCeiling(q) - back), ym = (yNew + yOld) / 2 + 3.5
            placer.put("↺ \(fall.hours > 2 ? "≥" : "+")\(Int(jsRound(back)))", .reset, .regular, .chartInk, [
                Placer.Spot(xs - 3, ym, .end), Placer.Spot(xs + 3, ym, .start), Placer.Spot(xs - 3, yNew - 4, .end),
                Placer.Spot(xs + 3, yNew - 4, .start), Placer.Spot(xs + 3, yOld + 11, .start),
            ])
        }
        for band in bandNames {
            placer.put(band.kind == .unrecorded ? "not recorded" : "not watched", band.kind, .regular, .chartInk,
                       [Placer.Spot(band.center, h - 4, .middle)])
        }

        plot = CGSize(width: w, height: h)
        self.axis = axis
        self.bands = bands
        self.strokes = strokes
        self.dots = dots
        labels = placer.placed
        self.ticks = ticks.labels
    }
}

/// How much of a limit a landing leaves, in whole percent, as the page's `whole` reads it.
private func left(_ landing: Double) -> Int { max(0, 100 - Int((landing + 1e-9).rounded(.down))) }

/// JavaScript's `Math.round`: the nearest whole number, and at a half the one above.
func jsRound(_ x: Double) -> Double {
    let down = x.rounded(.down)
    return x - down >= 0.5 ? down + 1 : down
}

let gapSeconds = 2 * hour

/// What colour a mark takes, by its role. The palette gives each its colour in each appearance.
public enum Tone: Hashable, Sendable {
    /// How much of the limit is left: green, amber or red.
    case level(Level)
    case ink, chartInk, rule, grid
    /// A limit's ceiling: the subject of the picture, so stronger than a rule.
    case ceiling
}

/// How much of a limit is left, in three steps: more than half, more than a fifth, or less.
public enum Level: Hashable, Sendable {
    case plenty, low, nearlyGone

    public init(used: Double) {
        let remaining = Int(min(100, max(0, 100 - used)).rounded(.down))
        self = remaining <= 20 ? .nearlyGone : remaining > 50 ? .plenty : .low
    }
}

public enum Weight: Hashable, Sendable { case regular, medium, semibold }

extension Verdict {
    /// The time the limit runs out, when the verdict says it does.
    var runsOutAt: Date? {
        if case .runsOut(let at, _, _) = self { at } else { nil }
    }

    /// Where the forecast's line goes: to the time it runs out, or to the reset with its landing.
    var path: (out: Date?, rate: Double, landing: Double)? {
        switch self {
        case .runsOut(let at, let rate, _): (at, rate, 100)
        case .lasts(let landing, let rate, _): (nil, rate, landing)
        case .spent, .silent: nil
        }
    }
}
