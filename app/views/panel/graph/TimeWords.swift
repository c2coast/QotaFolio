import Foundation

/// How the graph spells a time: the day's short name and the clock, in the calendar's time zone,
/// on a 24-hour or a 12-hour clock. The view spells its own words, so the clock is one of its
/// plain options.
public struct TimeWords: Sendable {
    public let calendar: Calendar
    public let twelveHour: Bool

    public init(calendar: Calendar, twelveHour: Bool = false) {
        self.calendar = calendar
        self.twelveHour = twelveHour
    }

    /// "Wed".
    public func weekday(_ t: Date) -> String {
        weekdays[calendar.component(.weekday, from: t) - 1]
    }

    /// "21:00", or "9:00 PM".
    public func clock(_ t: Date) -> String {
        let (hour, minute) = parts(t)
        guard twelveHour else { return "\(twoDigits(hour)):\(twoDigits(minute))" }
        return "\(hour % 12 == 0 ? 12 : hour % 12):\(twoDigits(minute)) \(hour < 12 ? "AM" : "PM")"
    }

    /// An hour on the axis: "12:00", or "12 PM".
    public func hour(_ t: Date) -> String {
        let (hour, _) = parts(t)
        guard twelveHour else { return "\(twoDigits(hour)):00" }
        return "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
    }

    /// "Wed 21:00": the day and the time to the minute, as the sentences say it.
    public func day(_ t: Date) -> String { "\(weekday(t)) \(clock(t))" }

    /// A forecast time to the nearest quarter hour. Its median error is about three hours, so a
    /// minute would be decoration.
    public func quarterDay(_ t: Date) -> String {
        let seconds = t.timeIntervalSince1970 / 900
        let down = seconds.rounded(.down)
        return day(Date(timeIntervalSince1970: (seconds - down >= 0.5 ? down + 1 : down) * 900))
    }

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
    func hourStart(_ t: Date) -> Date {
        calendar.dateInterval(of: .hour, for: t)!.start
    }

    func hourOfDay(_ t: Date) -> Int { calendar.component(.hour, from: t) }

    private func parts(_ t: Date) -> (Int, Int) {
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t.timeIntervalSince1970.rounded(.down)))
        return (c.hour!, c.minute!)
    }
}

private let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

private func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
