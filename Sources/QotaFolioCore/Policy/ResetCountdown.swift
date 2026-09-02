import Foundation

public nonisolated struct ResetCountdown: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case future
        case due
        case unavailable
    }

    public let visible: String
    public let spoken: String
    public let state: State

    public var isDue: Bool { state == .due }

    public init(visible: String, spoken: String, state: State) {
        self.visible = visible
        self.spoken = spoken
        self.state = state
    }

    public static func make(
        resetsAt: Date?,
        now: Date,
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone
    ) -> ResetCountdown {
        guard let resetsAt,
              isPresentationRepresentable(resetsAt),
              isPresentationRepresentable(now)
        else {
            return unavailable()
        }

        let interval = resetsAt.timeIntervalSince(now)
        guard interval.isFinite else {
            return unavailable()
        }

        guard interval > 0 else {
            let value = qfLocalized(
                "reset.due",
                defaultValue: "Reset due",
                comment: "Shown when a provider reset time has passed but fresh quota data has not arrived."
            )
            return ResetCountdown(visible: value, spoken: value, state: .due)
        }

        guard let seconds = wholeSeconds(interval) else {
            return unavailable()
        }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let visible: String
        if days > 0 {
            visible = qfLocalized(
                "reset.relative.daysHours",
                defaultValue: "\(days)d \(hours)h",
                comment: "Compact quota reset countdown with days and hours."
            )
        } else if hours > 0 {
            visible = qfLocalized(
                "reset.relative.hoursMinutes",
                defaultValue: "\(hours)h \(minutes)m",
                comment: "Compact quota reset countdown with hours and minutes."
            )
        } else if minutes > 0 {
            visible = qfLocalized(
                "reset.relative.minutes",
                defaultValue: "\(minutes)m",
                comment: "Compact quota reset countdown in minutes."
            )
        } else {
            visible = qfLocalized(
                "reset.relative.lessThanMinute",
                defaultValue: "<1m",
                comment: "Compact quota reset countdown for less than one minute."
            )
        }
        let spoken = SpokenDuration.spoken(seconds: seconds)

        _ = locale
        _ = calendar
        _ = timeZone
        return ResetCountdown(visible: visible, spoken: spoken, state: .future)
    }

    private static func unavailable() -> ResetCountdown {
        let value = qfLocalized(
            "reset.unavailable",
            defaultValue: "Reset time unavailable",
            comment: "Shown when a quota reset timestamp is absent or cannot be represented safely."
        )
        return ResetCountdown(visible: value, spoken: value, state: .unavailable)
    }

    private static func isPresentationRepresentable(_ date: Date) -> Bool {
        // Foundation formatters clamp dates beyond these bounds to unrelated calendar values.
        let value = date.timeIntervalSinceReferenceDate
        guard value.isFinite else { return false }
        return value >= Date.distantPast.timeIntervalSinceReferenceDate
            && value <= Date.distantFuture.timeIntervalSinceReferenceDate
    }

    private static func wholeSeconds(_ interval: TimeInterval) -> Int? {
        guard interval.isFinite,
              interval >= 0,
              interval < Double(Int.max)
        else {
            return nil
        }
        return Int(interval)
    }
}
