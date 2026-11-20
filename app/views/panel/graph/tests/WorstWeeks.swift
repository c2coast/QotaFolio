import Foundation
import Kit

/// Weeks the frozen record does not hold, made up from readings and run through the Engine, as
/// the record is. Each is a worst case for a graph: a clock change inside the week, banked resets
/// whose labels stack, ceilings that lie on each other, an account with only the week, a long
/// model name, the week's first poll, a reset at midnight.
///
/// An account is polled every 15 minutes, from a day before its week to the week's now. It works
/// from 9:00 to 23:00 on its own clock and rests at night, and a provider reports whole percents.
struct WorstWeek: Sendable {
    let name: String
    let zone: TimeZone
    /// The account's readings, from the week before to now.
    let readings: [Reading]
    let now: Date

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    var picture: WeekPicture { Forecast(readings: readings).picture(at: now)! }

    /// What happens at an hour of the week: a banked reset of the model's week alone, or of
    /// everything, or a burst of work that leaves the meters reading so much.
    enum Event {
        case model, full
        case reads(week: Double, model: Double)
    }

    /// - Parameters:
    ///   - reset: the week's reset, as year, month, day, hour and minute on the zone's clock.
    ///   - perHour: the week's points used in each hour of work.
    ///   - modelShare: how much of the work is on the model. A model point is half a week point, so
    ///     at 0.5 the model's percent rises as fast as the week's; above it, the model reads more
    ///     than its half of the week allows, as a provider whose model's share is smaller would.
    ///   - events: each banked reset or burst, by its hour after the week's start.
    ///   - now: the hour after the week's start that is now.
    init(_ name: String, zone: String, reset: (Int, Int, Int, Int, Int), model: String? = "Fable", perHour: Double,
         modelShare: Double = 0.3, events: [(hour: Double, event: Event)] = [], now: Double) {
        let zone = TimeZone(identifier: zone)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let resetAt = calendar.date(from: DateComponents(year: reset.0, month: reset.1, day: reset.2, hour: reset.3, minute: reset.4))!
        let start = resetAt - 7 * 86400
        let modelKind = model.map(Limit.Kind.modelWeek)

        var readings: [Reading] = []
        var week = 0.0, modelUsed = 0.0, pending = events.sorted { $0.hour < $1.hour }
        var t = start - 86400
        while t <= start + now * 3600 {
            let inWeek = t >= start
            let weekReset = ResetTime(inWeek ? resetAt : start)
            while inWeek, let next = pending.first, t >= start + next.hour * 3600 {
                pending.removeFirst()
                switch next.event {
                case .model: (week, modelUsed) = (max(0, week - modelUsed / 2), 1)
                case .full: (week, modelUsed) = (0, 0)
                case .reads(let w, let m): (week, modelUsed) = (w, m)
                }
            }
            func limit(_ kind: Limit.Kind, _ used: Double) -> Limit {
                Limit(kind: kind, used: Percent(min(100, used.rounded(.down)))!, resets: weekReset)
            }
            let shown = inWeek ? week : 30
            readings.append(Reading(account: AccountID("W"), at: t, limits: [limit(.week, shown)]
                + (modelKind.map { [limit($0, inWeek ? modelUsed : 20)] } ?? [])))

            let hour = calendar.component(.hour, from: t)
            if inWeek, hour >= 9, hour < 23, week < 100 {
                // Work comes in bursts: a little more in the afternoon, a little less late at night.
                let burst = 1 + 0.4 * sin(Double(hour) / 3)
                let used = perHour / 4 * burst
                week = min(100, week + used)
                modelUsed = min(100, modelUsed + used * modelShare * 2)
            }
            t += 900
        }
        self.name = name
        self.zone = zone
        self.readings = readings
        self.now = readings[readings.count - 1].at
    }

    static let all: [WorstWeek] = [
        // Summer time ends inside the week: London's Sunday has 25 hours.
        WorstWeek("clock-goes-back", zone: "Europe/London", reset: (2025, 10, 29, 21, 0), perHour: 1.4, now: 4 * 24 + 18),
        // Summer time starts inside the week: New York's Sunday has 23 hours.
        WorstWeek("clock-goes-forward", zone: "America/New_York", reset: (2026, 3, 11, 21, 0), perHour: 1.15, now: 5 * 24 + 15),
        // Five banked resets of the model's week, three of them inside one afternoon.
        WorstWeek("five-banked-resets", zone: "UTC", reset: (2025, 11, 26, 21, 0), perHour: 2.0, modelShare: 0.5,
                  events: [(30, .model), (64, .model), (67, .model), (70, .model), (100, .model)], now: 4 * 24 + 18),
        // Four banked resets of an account with only the week: each gives back everything.
        WorstWeek("four-full-resets", zone: "UTC", reset: (2025, 11, 26, 21, 0), model: nil, perHour: 2.4,
                  events: [(40, .full), (70, .full), (95, .full), (118, .full)], now: 5 * 24 + 22),
        // The model reads more than its half of the week allows, and two full resets lift its
        // ceiling to the week's: 50 + 2 × 80 / 2 = 100 + 2 × 15, so the two ceilings lie on each other.
        WorstWeek("ceilings-meet", zone: "UTC", reset: (2025, 11, 26, 21, 0), perHour: 0.4, modelShare: 2.7,
                  events: [(47.5, .reads(week: 15, model: 80)), (48, .full), (95.5, .reads(week: 15, model: 80)), (96, .full)],
                  now: 6 * 24 - 2),
        // An account with only the week, which runs out.
        WorstWeek("week-only", zone: "UTC", reset: (2025, 11, 26, 21, 0), model: nil, perHour: 1.3, now: 4 * 24 + 18),
        // A long model's name, whose week runs out first.
        WorstWeek("long-model-name", zone: "UTC", reset: (2025, 11, 26, 21, 0), model: "Claude Sonnet 4.5", perHour: 1.1,
                  modelShare: 0.8, now: 3 * 24 + 18),
        // The week's first poll, at its start: a picture of one point.
        WorstWeek("first-poll", zone: "UTC", reset: (2025, 11, 26, 21, 0), perHour: 1, now: 0),
        // The week resets at midnight, and the forecast runs out on the hour before it.
        WorstWeek("midnight-reset", zone: "Europe/London", reset: (2025, 11, 27, 0, 0), perHour: 1.6, now: 4 * 24 + 18),
    ]
}
