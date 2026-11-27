import Foundation
import Kit
import Testing

/// Four moments of the recorded week, each worked out by hand from the raw readings with the
/// method's rules. The arithmetic is written beside each test; the Engine is compared afterwards.
///
/// The rules, in short. The cumulative is the reading plus the points falls gave back this week.
/// The burn is the cumulative's rise over the last three hours, divided by the hours of that clock
/// when the meter was not at 100 percent; between two polls the cumulative runs straight. The burn
/// speaks when it has an hour of clock and two whole points of rise. Otherwise the week's pace
/// speaks: the cumulative since the week began at zero, over the week's unblocked clock. At a rate,
/// the limit runs out at now + (100 - reading) / rate, if that is before the reset; otherwise it
/// lands at reading + rate x hours to the reset. The verdict is silent when the reading half a
/// point lower at the step's higher rate, and half a point higher at its lower rate, disagree.
@Suite("The forecast at four moments, worked by hand")
struct MomentsTests {
    /// A, Thu 13 Nov 14:08:50. The week reads 20. Its week began Wed 12 21:00 and resets Wed 19
    /// 21:00; nothing was given back yet, so the cumulative is the reading.
    ///
    /// Three hours back is 11:08:50, between 10:54:29 at 0 and 11:10:53 at 3, so the cumulative
    /// there is 3 x 861 / 984 = 2.625. No poll in the three hours read 100.
    /// Burn = (20 - 2.625) / 3 = 5.7917 points an hour; 17.375 points of rise, so the burn speaks.
    /// 80 points to go / 5.7917 = 13.813 hours: Fri 14 Nov 03:57:36, before the reset.
    /// The step: 19.5 at (17.375 + 1) / 3 = 6.125 runs out Fri 03:17; 20.5 at (17.375 - 1) / 3 =
    /// 5.458 runs out Fri 04:42. Both run out, so it speaks.
    @Test("A, Thu 13 Nov 14:08: the burn says the week runs out Fri 14 Nov 03:57")
    func burnSpeed() throws {
        let poll = try Record.poll(Record.a, 13, 14, 8)
        guard case .runsOut(let at, let rate, let speed) = poll.verdicts[.week] else {
            Issue.record("expected the week to run out, got \(String(describing: poll.verdicts[.week]))")
            return
        }
        #expect(Record.minute(at) == "Fri 14 Nov 03:57")
        #expect(abs(rate - 5.7917) < 0.0001)
        #expect(speed == .burn)
    }

    /// B, Sat 15 Nov 19:56:41. The week reads 48. Its week began Fri 14 13:00 and resets Fri 21 13:00.
    ///
    /// At 18:28:38 the week read 97 and Fable 100; at 18:58:38, 48 and 2. Half of Fable's 100 is 50,
    /// and 97 - 50 = 47 is within five of 48, so Fable alone reset, and gave 50 points back to the
    /// week. The cumulative is 48 + 50 = 98.
    /// Three hours back, 16:56:41, the cumulative was 97, flat from 15:37:17 to 18:28:38. One point
    /// of rise is under two, so the burn is quiet and the week's pace speaks.
    /// The week's clock is 111401 seconds = 30.945 hours. The poll before the week began, Fri 14
    /// 12:48:02, read 100, but the week reset at 13:00:00 and could be spent from then, so none of
    /// it is blocked. Pace = 98 / 30.945 = 3.1669 points an hour.
    /// 52 points to go / 3.1669 = 16.420 hours: Sun 16 Nov 12:21:51, before the reset.
    /// The step: 47.5 at 3.1669 + 0.5 / 30.945 runs out Sun 12:26; 48.5 at 3.1669 - 0.5 / 30.945 runs
    /// out Sun 12:17. Both run out, so it speaks.
    @Test("B, Sat 15 Nov 19:56: 50 points given back, the week's pace says Sun 16 Nov 12:21")
    func weekPace() throws {
        let poll = try Record.poll(Record.b, 15, 19, 56)
        #expect(poll.givenBack[.week] == 50)
        guard case .runsOut(let at, let rate, let speed) = poll.verdicts[.week] else {
            Issue.record("expected the week to run out, got \(String(describing: poll.verdicts[.week]))")
            return
        }
        #expect(Record.minute(at) == "Sun 16 Nov 12:21")
        #expect(abs(rate - 3.1669) < 0.0001)
        #expect(speed == .weekPace)
    }

    /// B, Fri 14 Nov 13:15:17, the first poll of a week that reset at 13:00:00. The poll before it,
    /// 12:48:02, read 100 for the week and for Fable; this one reads 5 and 7.
    ///
    /// The limit could be spent from the reset on, so the 917 seconds since 13:00:00 are clock, not
    /// blocked time. Three hours back is before the week began, so the burn's clock is the week's:
    /// 0.2547 hours, under one hour, and the week's pace speaks.
    /// Pace = 5 / 0.2547 = 19.629 points an hour; 95 points / 19.629 = 4.840 hours: Fri 18:05:40.
    /// The step: 4.5 at 19.629 + 0.5 / 0.2547 = 21.592 runs out Fri 17:40; 5.5 at 17.666 runs out
    /// Fri 18:36. Both run out, so it speaks.
    /// Fable takes the week's pace at the week's mix, 7 / 5 = 1.4: 27.481 points an hour, and 93
    /// points run out Fri 16:38:20. The step: 6.5 at 30.229 runs out 16:20, 7.5 at 24.733 runs out
    /// 16:59. Both run out, so it speaks.
    ///
    /// Counted as blocked, those 917 seconds left no clock, and both limits were silent.
    @Test("B, Fri 14 Nov 13:15: the minutes after a spent week's reset are clock, and both limits run out")
    func afterSpentReset() throws {
        let poll = try Record.poll(Record.b, 14, 13, 15)
        guard case .runsOut(let at, let rate, let speed) = poll.verdicts[.week],
              case .runsOut(let fableAt, let fableRate, _) = poll.verdicts[Record.fable] else {
            Issue.record("expected both limits to run out, got \(poll.verdicts)")
            return
        }
        #expect(at == Record.moment(14, 18, 5, 40))
        #expect(abs(rate - 19.629) < 0.001)
        #expect(speed == .weekPace)
        #expect(fableAt == Record.moment(14, 16, 38, 20))
        #expect(abs(fableRate - 27.481) < 0.001)
    }

    /// A, Tue 18 Nov 20:43:36. The week reads 2, half an hour after a full banked reset took it
    /// from 98 to 1. The week resets Wed 19 21:00.
    ///
    /// Given back this week: 46.5 at the Fable reset of 14:11 (half of Fable's 93) and 98 at the
    /// full reset of 20:13, so 144.5, and the cumulative is 2 + 144.5 = 146.5.
    /// Three hours back, 17:43:36, lies between 17:43:15 (92 + 46.5 = 138.5) and 17:58:19 (139.5):
    /// 138.5 + 21 / 904 = 138.5232. Nothing was at 100 in those hours.
    /// Burn = (146.5 - 138.5232) / 3 = 2.6589 points an hour, from 7.98 points of rise.
    /// 98 points / 2.6589 = 36.86 hours: Thu 20 09:35, after the reset, so it lasts.
    /// Landing = 2 + 2.6589 x 24.2733 hours to the reset = 66.54.
    /// The step: 1.5 at 8.98 / 3 = 2.992 would reach 100 Thu 05:38; 2.5 at 6.98 / 3 = 2.326 Thu 14:39.
    /// Both after the reset, so it speaks.
    @Test("A, Tue 18 Nov 20:43: right after a full banked reset, the week lasts and lands at 66.54")
    func afterFullReset() throws {
        let poll = try Record.poll(Record.a, 18, 20, 43)
        guard case .lasts(let landing, let rate, let speed) = poll.verdicts[.week] else {
            Issue.record("expected the week to last, got \(String(describing: poll.verdicts[.week]))")
            return
        }
        #expect((landing * 100).rounded() / 100 == 66.54)
        #expect(abs(rate - 2.6589) < 0.0001)
        #expect(speed == .burn)
    }

    /// A, Tue 18 Nov 23:42:24. The week reads 15 and Fable 12. Given back: 144.5 to the week as
    /// above, and to Fable its 93 and its 51, so 144.
    ///
    /// The week: cumulative 159.5. Three hours back, 20:42:24, between 20:13:36 (145.5) and 20:43:36
    /// (146.5): 145.5 + 1728 / 1800 = 146.46. Burn = 13.04 / 3 = 4.3467 points an hour.
    /// 85 points / 4.3467 = 19.555 hours: Wed 19 Nov 19:15:42, 1 h 44 m before the reset.
    /// The step: 14.5 at 14.04 / 3 runs out Wed 17:58; 15.5 at 12.04 / 3 runs out Wed 20:45. Speaks.
    ///
    /// Fable takes the week's burn, scaled by the week's mix: Fable's cumulative 12 + 144 = 156 over
    /// the week's 159.5 = 0.97806. Rate 4.3467 x 0.97806 = 4.2513: 88 points run out Wed 20:24.
    /// The step: 11.5 at 4.68 x 0.97806 = 4.5773 runs out Wed 19:02, but 12.5 at 4.0133 x 0.97806 =
    /// 3.9253 would reach 100 Wed 21:59, after the reset. They disagree, so Fable is silent.
    @Test("A, Tue 18 Nov 23:42: the week says Wed 19 Nov 19:15, and Fable is silent inside one step")
    func insideOneStep() throws {
        let poll = try Record.poll(Record.a, 18, 23, 42)
        guard case .runsOut(let at, let rate, let speed) = poll.verdicts[.week] else {
            Issue.record("expected the week to run out, got \(String(describing: poll.verdicts[.week]))")
            return
        }
        #expect(Record.minute(at) == "Wed 19 Nov 19:15")
        #expect(abs(rate - 4.3467) < 0.0001)
        #expect(speed == .burn)
        #expect(poll.verdicts[Record.fable] == .silent(.insideOneStep))
    }
}
