import Foundation

/// A duration as VoiceOver should say it — one spelling for the strip and the panel.
///
/// The two largest units that are not zero, each with its own number: "3 days 4 hours",
/// "3 days", "2 hours 14 minutes", "1 hour 30 minutes", "47 minutes", "1 minute". Under a
/// minute it says so in words. Nothing here is drawn; the compact forms the eye reads live with
/// the surfaces that draw them.
public nonisolated enum SpokenDuration {
    public static func spoken(seconds: Int) -> String {
        let seconds = max(0, seconds)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 {
            return pair(self.days(days), hours > 0 ? self.hours(hours) : nil)
        }
        if hours > 0 {
            return pair(self.hours(hours), minutes > 0 ? self.minutes(minutes) : nil)
        }
        if minutes > 0 {
            return self.minutes(minutes)
        }
        return qfLocalized(
            "time.lessThanMinute",
            defaultValue: "less than a minute",
            comment: "A duration under one minute, spoken."
        )
    }

    public static func spoken(minutes: Int) -> String {
        spoken(seconds: max(0, minutes) * 60)
    }

    private static func pair(_ first: String, _ second: String?) -> String {
        guard let second else { return first }
        return qfLocalized(
            "time.pair",
            defaultValue: "\(first) \(second)",
            comment: "Two duration units said together, spoken: the larger first."
        )
    }

    private static func days(_ days: Int) -> String {
        days == 1
            ? qfLocalized("time.day", defaultValue: "1 day", comment: "One day, spoken.")
            : qfLocalized("time.days", defaultValue: "\(days) days", comment: "A whole number of days, spoken.")
    }

    private static func hours(_ hours: Int) -> String {
        hours == 1
            ? qfLocalized("time.hour", defaultValue: "1 hour", comment: "One hour, spoken.")
            : qfLocalized("time.hours", defaultValue: "\(hours) hours", comment: "A whole number of hours, spoken.")
    }

    private static func minutes(_ minutes: Int) -> String {
        minutes == 1
            ? qfLocalized("time.minute", defaultValue: "1 minute", comment: "One minute, spoken.")
            : qfLocalized("time.minutes", defaultValue: "\(minutes) minutes", comment: "A whole number of minutes, spoken.")
    }
}
