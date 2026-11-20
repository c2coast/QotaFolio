import Foundation
import Graph
import Kit
import Testing

/// The Ceiling graph's geometry at the chart page's twelve moments of the frozen record, at the
/// panel's size, in UTC.
@Suite("The Ceiling graph at the page's twelve moments")
struct CeilingTests {
    static let names = Record.moments.keys.sorted()
    static let size = CGSize(width: 360, height: 146)

    static func ceiling(_ name: String) throws -> Ceiling {
        Ceiling(picture: try Record.picture(name), size: size, words: TimeWords(calendar: Record.calendar))
    }

    @Test("Time runs left to right, from the week's start at 0 to the reset at the right edge", arguments: names)
    func order(_ name: String) throws {
        let picture = try Record.picture(name)
        let axis = try Self.ceiling(name).axis
        #expect(axis.x(picture.start) == 0)
        #expect(axis.x(picture.resets.instant) == Double(Self.size.width))
        #expect(axis.pieces.first?.from == picture.start && axis.pieces.last?.to == picture.resets.instant)
        for (a, b) in zip(axis.pieces, axis.pieces.dropFirst()) {
            #expect(a.to == b.from && a.x1 == b.x0, "\(name): the pieces touch, in order")
        }
        var t = picture.start, last = -1.0
        while t <= picture.resets.instant {
            let x = axis.x(t)
            #expect(x >= last, "\(name): at \(Record.minute(t))")
            last = x
            t += 60
        }
    }

    /// The folds of the chart page's own `timeAxis` at each moment, by kind and length in hours. The
    /// page's moment "Now" was the last poll of an older copy of the history. At the record's last
    /// reading the fold is worked by hand from the page's rule: the week has been spent since
    /// Thu 19:27 and resets Wed 21:00, so the fold holds 145.55 hours.
    static let pageFolds: [String: (TimeAxis.Fold, Double)?] = [
        "after-banked-reset": (.atLimit, 109.1), "after-a-gap": (.atLimit, 109.1), "before-the-reset": (.atLimit, 109.1),
        "spent-week": (.spent, 71.1), "last-reading": (.spent, 145.55),
        "new-week": (.afterForecast, 145.8), "fable-near-its-limit": (.afterForecast, 156.6), "longest-gap": (.afterForecast, 83.7),
        "out-in-15-minutes": (.afterForecast, 138.5), "fable-spent-week-not": (.afterForecast, 152.9),
        "record-starts-mid-week": (.afterForecast, 29.3), "new-week-at-zero": nil,
    ]

    @Test("The axis folds where the chart page's does, and a fold has its fixed width", arguments: names)
    func folds(_ name: String) throws {
        let pieces = try Self.ceiling(name).axis.pieces.filter { $0.fold != nil }
        let page = try #require(Self.pageFolds[name])
        #expect(pieces.count == (page == nil ? 0 : 1), "\(name)")
        for piece in pieces {
            let fold = try #require(piece.fold)
            #expect(fold == page?.0, "\(name)")
            #expect(abs(piece.to.timeIntervalSince(piece.from) / 3600 - (page?.1 ?? 0)) < 0.05, "\(name)")
            #expect(abs(piece.x1 - piece.x0 - (fold == .atLimit ? 34 : 56)) < 1e-9, "\(name)")
        }
    }

    @Test("After the two banked resets of Tuesday, the graph marks both, with what each gave back")
    func twoResets() throws {
        let marks = try Self.ceiling("after-banked-reset").labels.filter { $0.kind == .reset }
        #expect(marks.map(\.text).sorted() == ["↺ +47", "↺ +98"])
    }
}
