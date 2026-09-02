import Foundation

/// **The instrument's words.** Everything the depth behind a card says, rendered from the
/// assessment and the trace, in an informational voice: it names the time and the level, it
/// never quotes a probability, and it never tells the person what to do.
///
/// Here, in Core, for the reason `AssessmentSentences` is: these are the strings a person
/// reads, so they go through `qfLocalized` and the catalog.
public nonisolated enum InstrumentSentences {
    // MARK: - The window in hand

    /// "Session · since 11:11"
    public static func chartTitle(windowTitle: String, since: Date, style: SentenceStyle) -> String {
        qfLocalized(
            "instrument.chart.title",
            defaultValue: "\(windowTitle) · since \(PanelWords.clock(since, style: style))",
            comment: "Heading over the instrument's chart: the window's name, then the clock time its current occurrence opened."
        )
    }

    /// The projected end and its honest range, in words. Names the time; never quotes a
    /// probability.
    public static func landing(_ forecast: WindowForecast, now: Date, style: SentenceStyle) -> String {
        let reset = forecast.resetsAt.map { PanelWords.dayAndClock($0, now: now, style: style) } ?? ""
        switch forecast.verdict {
        case .onCourse:
            guard let landing = forecast.landingPercent else { return noProjection() }
            let percent = PanelWords.percent(AssessmentSentences.whole(landing), style: style)
            if let range = forecast.outerBand {
                return qfLocalized(
                    "instrument.landing.onCourse.range",
                    defaultValue: "On course to land near \(percent) used at \(reset) — between \(PanelWords.percent(AssessmentSentences.whole(range.lowPercent), style: style)) and \(PanelWords.percent(AssessmentSentences.whole(range.highPercent), style: style)).",
                    comment: "Instrument sentence for a window on course. The projected percentage used, the reset time, then the low and high ends of the range."
                )
            }
            return qfLocalized(
                "instrument.landing.onCourse",
                defaultValue: "On course to land near \(percent) used at \(reset).",
                comment: "Instrument sentence for a window on course. The projected percentage used, then the reset time."
            )
        case .cuttingItClose:
            guard let landing = forecast.landingPercent else { return noProjection() }
            let percent = PanelWords.percent(AssessmentSentences.whole(landing), style: style)
            if let range = forecast.outerBand {
                return qfLocalized(
                    "instrument.landing.close.range",
                    defaultValue: "Cutting it close: lands near \(percent) used at \(reset) — between \(PanelWords.percent(AssessmentSentences.whole(range.lowPercent), style: style)) and \(PanelWords.percent(AssessmentSentences.whole(range.highPercent), style: style)).",
                    comment: "Instrument sentence for a window projected to finish with little to spare. The projected percentage used, the reset time, then the low and high ends of the range."
                )
            }
            return qfLocalized(
                "instrument.landing.close",
                defaultValue: "Cutting it close: lands near \(percent) used at \(reset).",
                comment: "Instrument sentence for a window projected to finish with little to spare. The projected percentage used, then the reset time."
            )
        case .runningOut(let at):
            guard let at else {
                return qfLocalized(
                    "instrument.landing.runningOut",
                    defaultValue: "Reaches its limit before the reset at this pace.",
                    comment: "Instrument sentence for a window projected to run dry before its reset, when no instant can be named."
                )
            }
            let remaining = ResetCountdown.make(
                resetsAt: forecast.resetsAt,
                now: now,
                locale: style.locale,
                calendar: style.calendar,
                timeZone: style.timeZone
            )
            return qfLocalized(
                "instrument.landing.runningOut.at",
                defaultValue: "Reaches its limit around \(PanelWords.clock(at, style: style)) at this pace, with \(remaining.visible) still to run before the reset.",
                comment: "Instrument sentence for a window projected to run dry before its reset. The clock time it reaches its limit, then the countdown to the reset."
            )
        case .spent:
            return qfLocalized(
                "instrument.landing.spent",
                defaultValue: "Spent. Back at \(reset).",
                comment: "Instrument sentence for a window with nothing left. The argument is the reset time."
            )
        case .silent(let silence):
            switch silence {
            case .learningYourPattern:
                return qfLocalized("instrument.silent.learning", defaultValue: "Learning your pattern — a few more windows and the line continues.", comment: "Instrument sentence when there is too little history to project from.")
            case .noResetInstant:
                return qfLocalized("instrument.silent.noReset", defaultValue: "No reset time reported, so there is no end to project to.", comment: "Instrument sentence when the provider named no reset instant.")
            case .notStarted:
                return qfLocalized("instrument.silent.notStarted", defaultValue: "Nothing spent yet.", comment: "Instrument sentence when nothing has been spent in the window.")
            case .readingIsStale:
                return AssessmentSentences.rowDetail(forecast, now: now, style: style)
            case .tooEarlyToSay:
                return qfLocalized("instrument.silent.tooEarly", defaultValue: "Too early to say — the range is wider than a number would be honest about.", comment: "Instrument sentence when the projected range is too wide to name a number inside.")
            }
        }
    }

    /// What the instrument says under the line while the app has no assessment for the window.
    public static func noProjection() -> String {
        qfLocalized("instrument.noProjection", defaultValue: "No projection yet.", comment: "Instrument sentence when the app has not assessed this window.")
    }

    /// "12:31 · 21% used · +7 pt in 5 min" — the sample under the cursor and the step that
    /// brought it there.
    public static func readout(
        at: Date,
        usedPercent: Double,
        previous: (at: Date, usedPercent: Double)?,
        style: SentenceStyle
    ) -> String {
        let clock = PanelWords.clock(at, style: style)
        let percent = PanelWords.percent(AssessmentSentences.whole(usedPercent), style: style)
        guard let previous else {
            return qfLocalized(
                "instrument.readout",
                defaultValue: "\(clock) · \(percent) used",
                comment: "Instrument readout for the sample under the cursor: its clock time, then the percentage used."
            )
        }
        let step = Int((usedPercent - previous.usedPercent).rounded())
        let minutes = max(1, Int((at.timeIntervalSince(previous.at) / 60).rounded()))
        guard step != 0 else {
            return qfLocalized(
                "instrument.readout.flat",
                defaultValue: "\(clock) · \(percent) used · no change in \(minutes) min",
                comment: "Instrument readout for a sample that did not move: its clock time, the percentage used, then the minutes since the previous sample."
            )
        }
        return qfLocalized(
            "instrument.readout.step",
            defaultValue: "\(clock) · \(percent) used · \(step > 0 ? "+" : "")\(step) pt in \(minutes) min",
            comment: "Instrument readout for a sample that moved: its clock time, the percentage used, the signed step in points, then the minutes it took."
        )
    }

    // MARK: - The week

    /// "Five-hour windows · last seven days"
    public static func weekTitle() -> String {
        qfLocalized("instrument.week.title", defaultValue: "Five-hour windows · last seven days", comment: "Heading over the instrument's row of completed five-hour windows.")
    }

    /// How the week went and how many more windows fit — from `WeekPlan`, the app's own count.
    /// Silent about the ones ahead when the app is.
    public static func week(
        worked: Int,
        untouched: Int,
        plan: WeekPlan?,
        weeklyResetsAt: Date?,
        style: SentenceStyle
    ) -> String {
        let ledger = qfLocalized(
            "instrument.week.ledger",
            defaultValue: "\(spelled(worked, style: style, capitalized: true)) worked, \(spelled(untouched, style: style, capitalized: false)) untouched.",
            comment: "Instrument sentence counting the completed five-hour windows of the last seven days: how many were worked in, how many nobody touched. Both counts arrive in words."
        )
        guard let plan else {
            return ledger + " " + qfLocalized(
                "instrument.week.learning",
                defaultValue: "Learning your pattern before counting the ones ahead.",
                comment: "Instrument clause when the week's cost per window is not yet measured."
            )
        }
        let weekday = weeklyResetsAt.map { PanelWords.weekday($0, style: style) }
            ?? qfLocalized("instrument.week.theReset", defaultValue: "the reset", comment: "Stands in for the weekday of a weekly reset the provider did not name.")
        if let runsOut = plan.runsOutAt {
            return ledger + " " + qfLocalized(
                "instrument.week.runsOut",
                defaultValue: "The week runs out on \(PanelWords.weekday(runsOut, style: style)), before it resets \(weekday).",
                comment: "Instrument clause when the week is projected to run dry before its reset. The weekday it runs out, then the weekday it resets."
            )
        }
        guard let timeFor = plan.sessionsThereIsTimeFor else {
            return ledger + " " + qfLocalized(
                "instrument.week.funded",
                defaultValue: "The week can fund about \(plan.fundedSessions) more.",
                comment: "Instrument clause counting the windows the week can still pay for."
            )
        }
        if timeFor < plan.fundedSessions {
            return ledger + " " + qfLocalized(
                "instrument.week.timeShort",
                defaultValue: "About \(timeFor) more fit before \(weekday); the week could fund \(plan.fundedSessions).",
                comment: "Instrument clause when there is time for fewer windows than the week funds. The count that fit, the weekday of the reset, then the count the week funds."
            )
        }
        if timeFor > plan.fundedSessions {
            return ledger + " " + qfLocalized(
                "instrument.week.weekShort",
                defaultValue: "The week funds about \(plan.fundedSessions) more; there is time for \(timeFor) before \(weekday).",
                comment: "Instrument clause when the week funds fewer windows than there is time for. The count the week funds, the count that fit, then the weekday of the reset."
            )
        }
        return ledger + " " + qfLocalized(
            "instrument.week.exact",
            defaultValue: "About \(timeFor) more fit before \(weekday), and the week funds exactly that.",
            comment: "Instrument clause when the week funds exactly as many windows as there is time for. The count, then the weekday of the reset."
        )
    }

    /// A small count in words — "Seven", "none" — so the ledger reads as a sentence.
    private static func spelled(_ count: Int, style: SentenceStyle, capitalized: Bool) -> String {
        let word: String
        if count > 0 {
            let formatter = NumberFormatter()
            formatter.locale = style.locale
            formatter.numberStyle = .spellOut
            word = formatter.string(from: NSNumber(value: count)) ?? String(count)
        } else {
            word = qfLocalized(
                "instrument.week.none",
                defaultValue: "none",
                comment: "The count zero in the week's ledger: no completed window was worked in, or none was left untouched."
            )
        }
        guard capitalized, let first = word.first else { return word }
        return String(first).uppercased(with: style.locale) + word.dropFirst()
    }

    /// "Thu 14:00, 58 percent used" / "Thu 14:00, untouched" — one completed window.
    ///
    /// Nothing is written under a block, so this one sentence is both what the hover shows and
    /// what VoiceOver reads. It is worded to be heard as well as seen.
    public static func block(
        weekday: String,
        openedAt: String,
        usedPercentAtClose: Double,
        isHollow: Bool
    ) -> String {
        guard !isHollow else {
            return qfLocalized(
                "instrument.block.untouched",
                defaultValue: "\(weekday) \(openedAt), untouched",
                comment: "One completed five-hour window nobody worked in, shown on hover and read by VoiceOver. The weekday, then the clock time it opened at."
            )
        }
        return qfLocalized(
            "instrument.block.used",
            defaultValue: "\(weekday) \(openedAt), \(AssessmentSentences.whole(usedPercentAtClose)) percent used",
            comment: "One completed five-hour window, shown on hover and read by VoiceOver. The weekday, the clock time it opened at, then the whole percentage it closed at."
        )
    }

    // MARK: - The account's own numbers

    /// "Extra usage £12.40 of £150.00 this month"
    public static func extraUsage(_ extra: ExtraUsage, limit: Double, style: SentenceStyle) -> String {
        qfLocalized(
            "instrument.extraUsage",
            defaultValue: "Extra usage \(PanelWords.money(extra.usedCredits, currency: extra.currency, style: style)) of \(PanelWords.money(limit, currency: extra.currency, style: style)) this month",
            comment: "Instrument line for overage spend against a monthly cap. The amount spent, then the cap, both in the provider's currency."
        )
    }

    /// "796 credits ($31.84)" or "796 credits"
    public static func credits(_ credits: UsageCredits, style: SentenceStyle) -> String {
        guard let dollars = credits.dollars else {
            return qfLocalized(
                "instrument.credits",
                defaultValue: "\(credits.count) credits",
                comment: "Instrument line for prepaid credits when the app has no dollar rate for them."
            )
        }
        return qfLocalized(
            "instrument.credits.value",
            defaultValue: "\(credits.count) credits (\(PanelWords.money(dollars, currency: "USD", style: style)))",
            comment: "Instrument line for prepaid credits: the count, then their dollar value."
        )
    }

    public static func noExtraUsage() -> String {
        qfLocalized("instrument.noExtraUsage", defaultValue: "No extra usage", comment: "Instrument line when the account has no overage billing and no prepaid credits.")
    }
}
