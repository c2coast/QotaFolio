import Foundation
import Kit

/// The rule that places the words inside the plot: each tries its places in order and takes the
/// first that lies inside the plot, touches no word and no dot placed before it, and covers no line
/// of the record. A forecast's word tries first only the places that read as its own dot's, clear
/// of the marks of now, and takes any free place when none does. A word with a shorter form tries
/// that in each place next. A word with no such place is left out, never drawn over another and
/// never over the record.
struct Placer {
    let width: Double
    let height: Double
    private var taken: [CGRect] = []
    /// Each piece of the record's lines, with how far its stroke reaches either side of it.
    private var record: [(a: CGPoint, b: CGPoint, reach: Double)] = []
    private var nows: [CGPoint] = []
    private(set) var placed: [Ceiling.Label] = []

    /// A forecast's word lies within this many points of its own dot.
    static let byOwnDot = 20.0
    /// And it is nearer its own dot than either mark of now by this many points.
    static let ownDotMargin = 4.0

    init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// A place for a word: the baseline's start, middle or end.
    struct Spot {
        let x: Double
        let y: Double
        let anchor: Anchor

        init(_ x: Double, _ y: Double, _ anchor: Anchor) {
            self.x = x
            self.y = y
            self.anchor = anchor
        }
    }

    enum Anchor { case start, middle, end }

    /// A dot keeps words off a square around it.
    mutating func dot(_ center: CGPoint, _ radius: Double) {
        taken.append(CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
    }

    /// A mark of now: a dot, which a forecast's word also keeps clear of.
    mutating func now(_ center: CGPoint, _ radius: Double) {
        dot(center, radius)
        nows.append(center)
    }

    /// The record's lines, stroked this wide. No word covers them.
    mutating func record(_ lines: [[CGPoint]], width: Double) {
        for line in lines {
            record += zip(line, line.dropFirst()).map { ($0, $1, width / 2) }
        }
    }

    /// Places a word in the first of its spots that is free, and says whether it found one. Given
    /// its dot, a forecast's word takes only a spot that reads as that dot's.
    @discardableResult
    mutating func put(_ text: String, or short: String? = nil, _ kind: Ceiling.Label.Kind, _ weight: Weight, _ tone: Tone,
                      _ spots: [Spot], by dot: CGPoint? = nil) -> Bool {
        for text in [text] + (short.map { [$0] } ?? []) {
            let wide = ChartType.width(text, weight)
            for spot in spots {
                let x0 = spot.anchor == .end ? spot.x - wide : spot.anchor == .middle ? spot.x - wide / 2 : spot.x
                let box = CGRect(x: x0 - 1, y: spot.y - 9, width: wide + 2, height: 11)
                guard box.minX >= 0, box.maxX <= width, box.minY >= 0, box.maxY <= height,
                      !taken.contains(where: { overlap($0, box) }),
                      !record.contains(where: { crosses($0.a, $0.b, box.insetBy(dx: -$0.reach, dy: -$0.reach)) }),
                      dot.map({ reads(box, as: $0) }) ?? true else { continue }
                taken.append(box)
                placed.append(Ceiling.Label(kind: kind, text: text, weight: weight, tone: tone, box: box))
                return true
            }
        }
        return false
    }

    /// A word reads as its dot's when it lies by the dot, and each mark of now is further from it
    /// than the dot, by the margin. A mark that sits on the dot is the same place, and does not count.
    private func reads(_ box: CGRect, as dot: CGPoint) -> Bool {
        let margin = Self.ownDotMargin
        return distance(box, dot) <= Self.byOwnDot && nows.allSatisfy { now in
            hypot(now.x - dot.x, now.y - dot.y) < margin || distance(box, now) >= distance(box, dot) + margin
        }
    }
}

/// Two boxes overlap when they share some area; boxes that only touch do not.
func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
    a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
}

/// Whether the straight line from a to b passes through the box's inside. A line along its edge
/// does not.
func crosses(_ a: CGPoint, _ b: CGPoint, _ box: CGRect) -> Bool {
    // Liang and Barsky: the part of the line inside each of the four edges, as a span of 0 to 1.
    var enter = 0.0, leave = 1.0
    let dx = b.x - a.x, dy = b.y - a.y
    for (p, q) in [(-dx, a.x - box.minX), (dx, box.maxX - a.x), (-dy, a.y - box.minY), (dy, box.maxY - a.y)] {
        if p == 0 {
            if q <= 0 { return false }
        } else if p < 0 {
            enter = max(enter, q / p)
        } else {
            leave = min(leave, q / p)
        }
    }
    return enter < leave
}

/// How far a point lies from a box: zero inside it.
func distance(_ box: CGRect, _ p: CGPoint) -> Double {
    hypot(max(box.minX - p.x, 0, p.x - box.maxX), max(box.minY - p.y, 0, p.y - box.maxY))
}

/// The places around a point at the end of a forecast, in the order they are tried.
func around(_ p: CGPoint) -> [Placer.Spot] {
    let (x, y) = (p.x, p.y)
    return [
        .init(x + 7, y + 3.5, .start), .init(x - 7, y + 3.5, .end), .init(x - 4, y - 7, .end),
        .init(x + 4, y - 7, .start), .init(x - 4, y + 15, .end), .init(x + 4, y + 15, .start),
        .init(x - 4, y + 27, .end), .init(x - 4, y - 19, .end), .init(x + 4, y + 27, .start),
    ]
}

/// The axis under the plot: the grid lines, the days or the hours, and the marks of each fold.
///
/// When 12 hours take 40 points or more, the hours are named every 3, 6 or 12 hours, the first that
/// leaves 40 points between them, and a piece after a fold names its day first. Otherwise each
/// day's name sits in the middle of what shows of it. A word that would come within 6 points of
/// another is left out.
struct Ticks {
    private(set) var strokes: [Ceiling.Stroke] = []
    private(set) var labels: [Ceiling.Label] = []

    init(axis: TimeAxis, picture: WeekPicture, words: TimeWords, width: Double, height h: Double) {
        let now = picture.now.at
        var grid: [[CGPoint]] = [], dotted: [[CGPoint]] = []
        var taken: [(Double, Double)] = []
        func line(_ x: Double) -> [CGPoint] { [CGPoint(x: x, y: 0), CGPoint(x: x, y: h)] }
        func put(_ x: Double, _ text: String, current: Bool, _ anchor: Placer.Anchor = .middle, kind: Ceiling.Label.Kind = .tick) {
            let weight: Weight = current ? .semibold : .regular
            let wide = ChartType.width(text, weight)
            let a = anchor == .middle ? x - wide / 2 : anchor == .end ? x - wide : x
            guard a >= 0, a + wide <= width, !taken.contains(where: { a < $0.1 + 6 && $0.0 < a + wide + 6 }) else { return }
            taken.append((a, a + wide))
            labels.append(Ceiling.Label(kind: kind, text: text, weight: weight, tone: current ? .ink : .chartInk,
                                        box: CGRect(x: a, y: h + 4, width: wide, height: 11)))
        }

        if let step = [3, 6, 12].first(where: { Double($0) * hour / axis.secondsPerPoint >= 40 }) {
            for piece in axis.open {
                if piece.from > picture.start {
                    put(piece.x0 + 3, words.weekday(piece.from + 1), current: words.sameDay(piece.from + 1, now), .start)
                }
                var t = words.hourStart(piece.from)
                while t < piece.to {
                    defer { t += hour }
                    let hourOfDay = words.hourOfDay(t)
                    if t <= piece.from || hourOfDay % step != 0 { continue }
                    let midnight = hourOfDay == 0
                    if midnight { grid.append(line(axis.x(t))) } else { dotted.append(line(axis.x(t))) }
                    put(axis.x(t), midnight ? words.weekday(t) : words.hour(t), current: midnight && words.sameDay(t, now))
                }
            }
        } else {
            for piece in axis.open {
                let mids = words.midnights(piece.from, piece.to)
                grid += mids.map { line(axis.x($0)) }
                let edges = [piece.from] + mids + [piece.to]
                for (a, b) in zip(edges, edges.dropFirst()) where axis.x(b) - axis.x(a) >= 20 {
                    put((axis.x(a) + axis.x(b)) / 2, words.weekday(a + 60), current: now >= a && now < b)
                }
            }
        }
        strokes.append(Ceiling.Stroke(part: .grid, lines: grid, width: 1, dash: [], tone: .grid, opacity: 1, round: false))
        strokes.append(Ceiling.Stroke(part: .grid, lines: dotted, width: 1, dash: [1, 3], tone: .grid, opacity: 1, round: false))

        for piece in axis.pieces {
            guard let fold = piece.fold else { continue }
            if fold != .afterForecast {
                let end = piece.x1 - (fold == .spent ? 0 : 2)
                strokes.append(Ceiling.Stroke(part: .limitStretch, lines: [[CGPoint(x: piece.x0 + 2, y: h + 1.5), CGPoint(x: end, y: h + 1.5)]],
                                              width: 3, dash: [], tone: .level(.nearlyGone), opacity: 0.8, round: true))
            }
            func slashes(_ x: Double) -> [[CGPoint]] {
                [[CGPoint(x: x - 4, y: h + 4), CGPoint(x: x, y: h - 4)], [CGPoint(x: x, y: h + 4), CGPoint(x: x + 4, y: h - 4)]]
            }
            let marks = slashes(piece.x0 + 2) + (fold == .atLimit ? slashes(piece.x1 - 2) : [])
            strokes.append(Ceiling.Stroke(part: .foldBreak, lines: marks, width: 1, dash: [], tone: .chartInk, opacity: 1, round: false))
            if fold != .atLimit { put(width, words.day(picture.resets.instant), current: false, .end, kind: .resetTime) }
        }
        strokes.removeAll { $0.lines.isEmpty }
    }
}

/// The calendar's walk that the axis needs, beside the words that say each time.
extension TimeWords {
    /// Two times fall on the same day of the calendar.
    func sameDay(_ a: Date, _ b: Date) -> Bool { calendar.isDate(a, inSameDayAs: b) }

    /// Every midnight after `from` and before `to`.
    func midnights(_ from: Date, _ to: Date) -> [Date] {
        var out: [Date] = []
        var t = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: from))!
        while t < to {
            out.append(t)
            t = calendar.date(byAdding: .day, value: 1, to: t)!
        }
        return out
    }

    /// The whole hour at or before the time.
    func hourStart(_ t: Date) -> Date { calendar.dateInterval(of: .hour, for: t)!.start }

    func hourOfDay(_ t: Date) -> Int { calendar.component(.hour, from: t) }
}
