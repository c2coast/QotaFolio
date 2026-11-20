import Foundation

/// How the product says a time: the day's short name and the clock, in the calendar's time zone,
/// on a 24-hour or a 12-hour clock. The sentences and the graph both say a time through it, so a
/// time reads the same in the picture and under it.
///
/// On a 24-hour clock it says what the chart page says, "Wed 21:00". On a 12-hour clock it says
/// "Wed 9:00 PM". English only.
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

    /// An hour on the graph's axis: "12:00", or "12 PM".
    public func hour(_ t: Date) -> String {
        let (hour, _) = parts(t)
        guard twelveHour else { return "\(twoDigits(hour)):00" }
        return "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
    }

    /// "Wed 21:00": the day and the time to the minute.
    public func day(_ t: Date) -> String { "\(weekday(t)) \(clock(t))" }

    /// A forecast time to the nearest quarter hour, as the page's `dq`. Its median error is about
    /// three hours, so a minute would be decoration.
    public func quarterDay(_ t: Date) -> String { day(Self.quarterHour(t)) }

    /// The nearest quarter hour, and at a half the one after, as the page rounds.
    public static func quarterHour(_ t: Date) -> Date {
        let quarters = t.timeIntervalSince1970 / 900
        let down = quarters.rounded(.down)
        return Date(timeIntervalSince1970: (quarters - down >= 0.5 ? down + 1 : down) * 900)
    }

    /// The hour and minute, from the whole second at or before the time, as the page's clock.
    private func parts(_ t: Date) -> (Int, Int) {
        let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: t.timeIntervalSince1970.rounded(.down)))
        return (c.hour!, c.minute!)
    }
}

private let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

private func twoDigits(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
