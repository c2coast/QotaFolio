import Foundation

extension Forecast {
    /// The account's week at the poll in force at the moment, as the graph draws it. None before
    /// the first poll.
    public func picture(at moment: Date) -> WeekPicture? {
        guard let i = polls.lastIndex(where: { $0.reading.at <= moment }) else { return nil }
        let poll = polls[i]
        let now = poll.reading.at
        let model = poll.verdicts.keys.first { $0 != .week }
        // A reset is known to the minute, so a poll can carry its new week a moment before the
        // week's start. The poll in force is always in its own week.
        let start = min(poll.resets.instant - secondsPerWeek, now)

        var points = polls[...i].filter { $0.reading.at >= start }.map { Self.point($0, model) }
        var unrecorded: DateInterval?
        if points[0].at.timeIntervalSince(start) > 60 {
            if polls[0].reading.at < start {
                let zero = WeekPicture.Meter(used: 0, givenBack: 0)
                points.insert(WeekPicture.Point(at: start, week: zero, model: model.map { _ in zero }, polled: false), at: 0)
            } else {
                unrecorded = DateInterval(start: start, end: points[0].at)
            }
        }

        let falls = self.falls.filter { $0.after.at > start && $0.after.at <= now }
        let gaps = zip(points, points.dropFirst())
            .filter { before, after in after.at.timeIntervalSince(before.at) > WeekPicture.gapSeconds }
            .map { before, after in WeekPicture.Gap(before: before, after: after, fall: falls.first { $0.after.at == after.at }) }

        var atLimit: [DateInterval] = []
        for (k, point) in points.enumerated() where point.week.used >= 100 {
            let end = k + 1 < points.count ? points[k + 1].at : now
            if let last = atLimit.last, last.end == point.at {
                atLimit[atLimit.count - 1] = DateInterval(start: last.start, end: end)
            } else {
                atLimit.append(DateInterval(start: point.at, end: end))
            }
        }

        return WeekPicture(account: poll.reading.account, model: model, start: start, resets: poll.resets, points: points,
                           unrecorded: unrecorded, falls: falls, gaps: gaps, atLimit: atLimit, verdicts: poll.verdicts,
                           forecast: AccountForecast(poll: poll))
    }

    private static func point(_ poll: Poll, _ model: Limit.Kind?) -> WeekPicture.Point {
        func meter(_ kind: Limit.Kind) -> WeekPicture.Meter {
            WeekPicture.Meter(used: poll.reading.limit(kind)?.used.value ?? 0, givenBack: poll.givenBack[kind] ?? 0)
        }
        return WeekPicture.Point(at: poll.reading.at, week: meter(.week), model: model.map(meter), polled: true)
    }
}
