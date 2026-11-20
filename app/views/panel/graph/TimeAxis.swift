import Foundation
import Kit

/// The graph's time axis: the week from its start to its reset, left to right, with the time in
/// which nothing could happen folded into a narrow strip of fixed width. The record and the
/// forecast get the width.
///
/// Three stretches fold. A stretch of 12 hours or more at the limit, unless it still runs while
/// the week is spent. When the week is spent, the last stretch at the limit to the reset, if it
/// began 12 hours or more before the reset. When the week's forecast runs out at a time E after
/// now, the time from M to the reset, where M is E plus the larger of an hour and 0.06 of the
/// time from the week's start to E, if the reset is more than 12 hours after M. Every other
/// second shares the rest of the width at one rate.
public struct TimeAxis: Hashable, Sendable {
    public enum Fold: Hashable, Sendable {
        /// A stretch of 12 hours or more at the limit, over before now.
        case atLimit
        /// The week is spent: its last stretch at the limit, on to the reset.
        case spent
        /// The days after the forecast says the week runs out, to the reset.
        case afterForecast

        /// A fold's width in points, whatever time it holds.
        public var width: Double { self == .atLimit ? 34 : 56 }
    }

    /// A run of the axis: open time at the shared rate, or a fold.
    public struct Piece: Hashable, Sendable {
        public let from: Date
        public let to: Date
        public let x0: Double
        public let x1: Double
        public let fold: Fold?
    }

    /// The pieces in time order. The first starts at the week's start and x 0, the last ends at
    /// the reset and the axis's width.
    public let pieces: [Piece]
    /// Seconds of open time for each point of width.
    public let secondsPerPoint: Double

    init(picture: WeekPicture, width: Double) {
        let start = picture.start.timeIntervalSince1970
        let reset = picture.resets.instant.timeIntervalSince1970
        let now = picture.now.at

        var folds: [(from: Double, to: Double, fold: Fold)] = []
        for stretch in picture.atLimit where stretch.duration >= 12 * hour && !(picture.spent && stretch.end >= now) {
            folds.append((stretch.start.timeIntervalSince1970, stretch.end.timeIntervalSince1970, .atLimit))
        }
        if picture.spent, let last = picture.atLimit.last, reset - last.start.timeIntervalSince1970 >= 12 * hour {
            folds.append((last.start.timeIntervalSince1970, reset, .spent))
        }
        if !picture.spent, case .runsOut(let out, _, _)? = picture.verdicts[.week], out > now {
            let e = out.timeIntervalSince1970
            let m = e + max(hour, (e - start) * 0.06)
            if reset - m > 12 * hour { folds.append((m, reset, .afterForecast)) }
        }
        folds.sort { $0.from < $1.from }

        let open = (reset - start) - folds.reduce(0) { $0 + $1.to - $1.from }
        let room = width - folds.reduce(0) { $0 + $1.fold.width }
        var pieces: [Piece] = []
        var t = start, x = 0.0
        func piece(_ from: Double, _ to: Double, _ x1: Double, _ fold: Fold?) {
            pieces.append(Piece(from: Date(timeIntervalSince1970: from), to: Date(timeIntervalSince1970: to), x0: x, x1: x1, fold: fold))
            x = x1
        }
        for fold in folds {
            if fold.from > t { piece(t, fold.from, x + room * (fold.from - t) / open, nil) }
            piece(fold.from, fold.to, x + fold.fold.width, fold.fold)
            t = fold.to
        }
        if t < reset { piece(t, reset, width, nil) }
        self.pieces = pieces
        secondsPerPoint = open / room
    }

    /// Where a time sits, in points from the left. A time inside a fold sits inside its strip.
    public func x(_ t: Date) -> Double {
        let p = pieces.first { t <= $0.to } ?? pieces[pieces.count - 1]
        let a = p.from.timeIntervalSince1970, b = p.to.timeIntervalSince1970
        let s = min(max(t.timeIntervalSince1970, a), b)
        return s == b ? p.x1 : p.x0 + (s - a) / (b - a) * (p.x1 - p.x0)
    }

    /// The time at a point from the left: the inverse of `x`, for a cursor.
    public func time(at x: Double) -> Date {
        let p = pieces.first { x <= $0.x1 } ?? pieces[pieces.count - 1]
        let a = p.from.timeIntervalSince1970, b = p.to.timeIntervalSince1970
        return Date(timeIntervalSince1970: a + (x - p.x0) / (p.x1 - p.x0) * (b - a))
    }

    /// The pieces that are open time.
    var open: [Piece] { pieces.filter { $0.fold == nil } }
}

let hour = 3600.0
