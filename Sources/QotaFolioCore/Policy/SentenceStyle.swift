import Foundation

/// How the sentences are spelled for this person: their language, their calendar, their
/// clock.
public nonisolated struct SentenceStyle: Equatable, Sendable {
    public let locale: Locale
    public let calendar: Calendar
    public let timeZone: TimeZone

    public init(
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.locale = locale
        self.calendar = calendar
        self.timeZone = timeZone
    }
}
