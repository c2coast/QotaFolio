import Foundation

public nonisolated extension Locale {
    /// Whether the person's clock runs to twelve, "9:00 PM", as the time words take it. The app
    /// and `qota` read it from the same locale, so a time reads the same in both.
    var clockIsTwelveHour: Bool { hourCycle == .oneToTwelve || hourCycle == .zeroToEleven }
}
