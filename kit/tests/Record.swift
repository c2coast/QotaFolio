import Foundation
import Kit
import Testing

/// The frozen record: version 1.0.0's history file of the owner's two accounts, A and B, from
/// Wed 12 Nov 2025 14:12 to Fri 21 Nov 2025 14:31. Every time is moved by a whole number of weeks
/// from when it was recorded, which changes no verdict, and the accounts are renamed.
///
/// The tests read it through the reader of 1.0.0's history. Every moment is written in UTC on the
/// Gregorian calendar, whatever the Mac running the tests is set to.
enum Record {
    static let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "fixtures")

    static let accounts: [[Reading]] = {
        let data = try! Data(contentsOf: fixtures.appending(path: "usage-history.json"))
        return try! LegacyHistory.readings(history: data, snapshots: nil)
    }()

    static let a = Forecast(readings: accounts[0])
    static let b = Forecast(readings: accounts[1])

    /// The last poll of either account: where the record ends.
    static let end = accounts.compactMap { $0.last?.at }.max()!

    static let fable = Limit.Kind.modelWeek("Fable")

    /// The chart page's twelve moments of the record, by name, from `fixtures/moments.json`.
    static let moments: [String: Moment] = {
        let data = try! Data(contentsOf: fixtures.appending(path: "moments.json"))
        let list = try! JSONDecoder().decode([Moment].self, from: data)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, $0) })
    }()

    struct Moment: Decodable {
        let name, label, account: String
        let at: Double
    }

    /// The account's week at a named moment.
    static func picture(_ name: String) throws -> WeekPicture {
        let moment = try #require(moments[name])
        let forecast = moment.account == "A" ? a : b
        return try #require(forecast.picture(at: Date(timeIntervalSince1970: moment.at)))
    }

    static let zone = TimeZone(identifier: "UTC")!

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }()

    /// A moment in UTC: `moment(18, 23, 42)` is Tue 18 Nov 2025 23:42:00.
    static func moment(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2025, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }

    /// The account's poll inside the named minute.
    static func poll(_ forecast: Forecast, _ day: Int, _ hour: Int, _ minute: Int) throws -> Forecast.Poll {
        let from = moment(day, hour, minute)
        return try #require(forecast.polls.first { $0.reading.at >= from && $0.reading.at < from + 60 })
    }

    /// A time to the minute, in UTC: "Fri 14 Nov 03:57".
    static func minute(_ date: Date) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(weekday: .abbreviated) \(day: .twoDigits) \(month: .abbreviated) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: Locale(identifier: "en_GB"), timeZone: calendar.timeZone, calendar: calendar))
    }
}
