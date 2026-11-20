import Foundation
import Kit

/// The rule that places the words inside the plot: each tries its places in order and takes the
/// first that lies inside the plot and touches no word and no dot placed before it. A word with
/// no such place is left out, never drawn over another.
struct Placer {
    let width: Double
    let height: Double
    private var taken: [CGRect] = []
    private(set) var placed: [Ceiling.Label] = []

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

    mutating func put(_ text: String, _ kind: Ceiling.Label.Kind, _ weight: Weight, _ tone: Tone, _ spots: [Spot],
                      measure: (String, Weight) -> CGSize) {
        let wide = measure(text, weight).width
        for spot in spots {
            let x0 = spot.anchor == .end ? spot.x - wide : spot.anchor == .middle ? spot.x - wide / 2 : spot.x
            let box = CGRect(x: x0 - 1, y: spot.y - 9, width: wide + 2, height: 11)
            guard box.minX >= 0, box.maxX <= width, box.minY >= 0, box.maxY <= height,
                  !taken.contains(where: { overlap($0, box) }) else { continue }
            taken.append(box)
            placed.append(Ceiling.Label(kind: kind, text: text, weight: weight, tone: tone, box: box, halo: true))
            return
        }
    }
}

/// Two boxes overlap when they share some area; boxes that only touch do not.
func overlap(_ a: CGRect, _ b: CGRect) -> Bool {
    a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
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
/// When a day is wide, each day's name sits in the middle of what shows of it. When it is narrow,
/// the hours are named every 3, 6 or 12 hours, whichever leaves 40 points between them, and a
/// piece after a fold names its day first. A word that would come within 6 points of another is
/// left out.
struct Ticks {
    private(set) var strokes: [Ceiling.Stroke] = []
    private(set) var labels: [Ceiling.Label] = []

    init(axis: TimeAxis, picture: WeekPicture, words: TimeWords, width: Double, height h: Double,
         measure: (String, Weight) -> CGSize) {
        let now = picture.now.at
        var grid: [[CGPoint]] = [], dotted: [[CGPoint]] = []
        var taken: [(Double, Double)] = []
        func line(_ x: Double) -> [CGPoint] { [CGPoint(x: x, y: 0), CGPoint(x: x, y: h)] }
        func put(_ x: Double, _ text: String, current: Bool, _ anchor: Placer.Anchor = .middle, kind: Ceiling.Label.Kind = .tick) {
            let weight: Weight = current ? .semibold : .regular
            let wide = measure(text, weight).width
            let a = anchor == .middle ? x - wide / 2 : anchor == .end ? x - wide : x
            guard a >= 0, a + wide <= width, !taken.contains(where: { a < $0.1 + 6 && $0.0 < a + wide + 6 }) else { return }
            taken.append((a, a + wide))
            labels.append(Ceiling.Label(kind: kind, text: text, weight: weight, tone: current ? .ink : .chartInk,
                                        box: CGRect(x: a, y: h + 4, width: wide, height: 11), halo: false))
        }

        if axis.secondsPerPoint * 50 >= 20 * hour {
            for piece in axis.open {
                let mids = words.midnights(piece.from, piece.to)
                grid += mids.map { line(axis.x($0)) }
                let edges = [piece.from] + mids + [piece.to]
                for (a, b) in zip(edges, edges.dropFirst()) where axis.x(b) - axis.x(a) >= 20 {
                    put((axis.x(a) + axis.x(b)) / 2, words.weekday(a + 60), current: now >= a && now < b)
                }
            }
        } else {
            let step = [3, 6, 12].first { Double($0) * hour / axis.secondsPerPoint >= 40 } ?? 24
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
