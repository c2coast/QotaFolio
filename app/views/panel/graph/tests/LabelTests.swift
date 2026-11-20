import Foundation
import Graph
import Kit
import Testing

/// A week as the graph is handed it: a named moment of the frozen record in UTC, or a made-up
/// worst week on its own clock.
struct Week: Sendable, CustomTestStringConvertible {
    let name: String
    let picture: WeekPicture
    let calendar: Calendar

    var testDescription: String { name }

    static let all: [Week] = Record.moments.keys.sorted().map { Week(name: $0, picture: try! Record.picture($0), calendar: Record.calendar) }
        + WorstWeek.all.map { Week(name: $0.name, picture: $0.picture, calendar: $0.calendar) }

    /// Narrower than the panel's 360 points, the panel's, and wider.
    static let widths: [Double] = [280, 360, 520]

    func ceiling(width: Double, twelveHour: Bool) -> Ceiling {
        Ceiling(picture: picture, size: CGSize(width: width, height: 146), words: words(twelveHour))
    }

    func words(_ twelveHour: Bool) -> TimeWords { TimeWords(calendar: calendar, twelveHour: twelveHour) }
}

/// The labels' rule, over every week the tests know, on both clocks and at three widths: each
/// word takes a free place or is left out, and the words the picture cannot do without are kept.
@Suite("The graph's words in every week")
struct LabelTests {
    @Test("Every word has a place of its own inside the chart, in an ink that reads", arguments: Week.all, [false, true])
    func placed(_ week: Week, twelveHour: Bool) {
        for width in Week.widths {
            let ceiling = week.ceiling(width: width, twelveHour: twelveHour)
            let plot = CGRect(origin: .zero, size: ceiling.plot)
            let under = CGRect(x: 0, y: ceiling.plot.height, width: width, height: Ceiling.axisBand)
            let at = "\(week.name) at \(Int(width)) points\(twelveHour ? ", 12-hour" : "")"
            for words in [ceiling.labels, ceiling.ticks] {
                for (i, a) in words.enumerated() {
                    for b in words[(i + 1)...] {
                        let overlap = a.box.minX < b.box.maxX && b.box.minX < a.box.maxX && a.box.minY < b.box.maxY && b.box.minY < a.box.maxY
                        #expect(!overlap, "\(at): \(a.text) at \(a.box) overlaps \(b.text) at \(b.box)")
                    }
                }
            }
            for label in ceiling.labels { #expect(plot.contains(label.box), "\(at): \(label.text) at \(label.box)") }
            for tick in ceiling.ticks { #expect(under.contains(tick.box), "\(at): \(tick.text) at \(tick.box)") }
            for word in ceiling.labels + ceiling.ticks {
                #expect(word.tone == .ink || word.tone == .chartInk, "\(at): \(word.text) is in \(word.tone)")
            }
        }
    }

    /// A word left out is no loss when the sentence under the graph says it. Two are not in the
    /// sentence's place: the time the first limit runs out, which is the picture's point, and the
    /// name of the week's ceiling, which is its subject.
    @Test("A picture keeps the first limit's time and the week's limit", arguments: Week.all, [false, true])
    func kept(_ week: Week, twelveHour: Bool) {
        let first: Limit.Kind? = switch week.picture.forecast {
        case .runsOut(let first, _, _, _): first
        case .modelSpent(week: .runsOut): .week
        default: nil
        }
        for width in Week.widths {
            let kinds = week.ceiling(width: width, twelveHour: twelveHour).labels.map(\.kind)
            let at = "\(week.name) at \(Int(width)) points\(twelveHour ? ", 12-hour" : "")"
            if let first { #expect(kinds.contains(.forecast(first)), "\(at): the forecast's time is left out") }
            #expect(kinds.contains(.limit(.week)), "\(at): the week's limit is left out")
        }
    }

    /// The record is never cut, so no label may sit on it. The test walks each of the record's
    /// lines half a point at a time and finds no step inside a label's box, widened by the stroke.
    @Test("No label covers a line of the record", arguments: Week.all, [false, true])
    func recordWhole(_ week: Week, twelveHour: Bool) {
        for width in Week.widths {
            let ceiling = week.ceiling(width: width, twelveHour: twelveHour)
            let at = "\(week.name) at \(Int(width)) points\(twelveHour ? ", 12-hour" : "")"
            for stroke in ceiling.strokes {
                guard case .record = stroke.part else { continue }
                for line in stroke.lines {
                    for (a, b) in zip(line, line.dropFirst()) {
                        let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) * 2))
                        for label in ceiling.labels {
                            let box = label.box.insetBy(dx: -stroke.width / 2, dy: -stroke.width / 2).insetBy(dx: 0.01, dy: 0.01)
                            let covered = (0...steps).contains { k in
                                let t = Double(k) / Double(steps)
                                return box.contains(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                            }
                            #expect(!covered, "\(at): \(label.text) at \(label.box) covers the record from \(a) to \(b)")
                        }
                    }
                }
            }
        }
    }

    /// A forecast's label names the dot where its line ends. Where a place by that dot is free, the
    /// label sits nearer the dot than the ring of now and the model's dot of now, so it does not read
    /// as their name. A mark of now that sits on the dot, when the limit runs out within minutes, is
    /// the same place.
    @Test("A forecast's label sits by its own dot, clear of the marks of now", arguments: Week.all, [false, true])
    func byOwnDot(_ week: Week, twelveHour: Bool) {
        func distance(_ box: CGRect, _ p: CGPoint) -> Double {
            hypot(max(box.minX - p.x, 0, p.x - box.maxX), max(box.minY - p.y, 0, p.y - box.maxY))
        }
        for width in Week.widths {
            let ceiling = week.ceiling(width: width, twelveHour: twelveHour)
            let at = "\(week.name) at \(Int(width)) points\(twelveHour ? ", 12-hour" : "")"
            guard !Self.noPlaceByTheDot.contains(at), let ring = ceiling.dots.first(where: \.ring) else { continue }
            let nows = ceiling.dots.filter { $0.center.x == ring.center.x }.map(\.center)
            for label in ceiling.labels {
                guard case .forecast(let kind) = label.kind,
                      let end = ceiling.strokes.first(where: { $0.part == .forecast(kind) })?.lines.last?.last else { continue }
                for now in nows where hypot(now.x - end.x, now.y - end.y) >= 4 {
                    #expect(distance(label.box, now) > distance(label.box, end),
                            "\(at): \(label.text) at \(label.box) is nearer the mark of now at \(now) than its dot at \(end)")
                }
            }
        }
    }

    /// The one week, worked by hand, where no place by a forecast's dot is free, so its label takes
    /// the first free place and is kept. Fable's red dot is 70 points from the plot's right edge,
    /// and "Wed 11:00 PM" needs 75.5 to its right. Every place to its left or below lies nearer the
    /// ring of now.
    static let noPlaceByTheDot: Set = ["record-starts-mid-week at 280 points, 12-hour"]

    /// A forecast's label that says when its limit runs out, "Weekly · Wed 7:15 PM" or the time
    /// alone, and the sentence under the graph say the same time in the same words, on either clock.
    @Test("The forecast's label and its sentence say the time the same way", arguments: Week.all, [false, true])
    func sameTime(_ week: Week, twelveHour: Bool) {
        let sentence = week.picture.sentences(in: week.words(twelveHour)).forecast
        for width in Week.widths {
            for label in week.ceiling(width: width, twelveHour: twelveHour).labels where !label.text.hasSuffix("left") {
                guard case .forecast = label.kind, let time = label.text.components(separatedBy: " · ").last else { continue }
                #expect(sentence.contains("around \(time)"), "\(week.name): \(label.text) beside “\(sentence)”")
            }
        }
    }

    /// A clock change makes one day of the week 23 or 25 hours long. Each day is still named once,
    /// in order, under the axis.
    @Test("Under the axis, each day's name comes once and in order", arguments: Week.all)
    func days(_ week: Week) {
        let order = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        for width in Week.widths {
            let names = week.ceiling(width: width, twelveHour: false).ticks.filter { order.contains($0.text) }
                .sorted { $0.box.minX < $1.box.minX }.map(\.text)
            #expect(Set(names).count == names.count, "\(week.name) at \(Int(width)) points: \(names)")
            let steps = zip(names, names.dropFirst()).map { a, b in (order.firstIndex(of: b)! - order.firstIndex(of: a)! + 7) % 7 }
            // In order, the steps from one name to the next go once round the week at most.
            #expect(steps.reduce(0, +) <= 6, "\(week.name) at \(Int(width)) points: \(names)")
        }
    }
}
