import Foundation

/// The parts of the panel the app spells the same way everywhere: a clock time, a day and a
/// clock, a percentage, money, a weekday. Every one is a formatter over the person's own
/// locale, calendar and clock (`SentenceStyle`), so the card, the instrument and the sentence
/// VoiceOver speaks cannot spell one instant three ways.
public nonisolated enum PanelWords {
    /// "16:11" — the clock time as the app prints it in its sentences.
    public static func clock(_ date: Date, style: SentenceStyle) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: style.locale,
                calendar: style.calendar,
                timeZone: style.timeZone
            )
        )
    }

    /// "16:11" today, "Thu 09:00" on another day. A reset that is not today says which day.
    public static func dayAndClock(_ date: Date, now: Date, style: SentenceStyle) -> String {
        guard !style.calendar.isDate(date, inSameDayAs: now) else { return clock(date, style: style) }
        let day = date.formatted(
            Date.FormatStyle(locale: style.locale, calendar: style.calendar, timeZone: style.timeZone)
                .weekday(.abbreviated)
        )
        return "\(day) \(clock(date, style: style))"
    }

    /// "Thursday"
    public static func weekday(_ date: Date, style: SentenceStyle) -> String {
        date.formatted(
            Date.FormatStyle(locale: style.locale, calendar: style.calendar, timeZone: style.timeZone)
                .weekday(.wide)
        )
    }

    /// "38%" — a whole percentage in the person's locale.
    public static func percent(_ whole: Int, style: SentenceStyle) -> String {
        (Double(whole) / 100).formatted(.percent.precision(.fractionLength(0)).locale(style.locale))
    }

    /// "£12.40" — money in the provider's currency, never a hardcoded dollar.
    public static func money(_ amount: Double, currency: String?, style: SentenceStyle) -> String {
        amount.formatted(.currency(code: currency ?? "USD").locale(style.locale))
    }
}
