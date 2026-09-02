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

/// **The words.** Everything the app says about the assessment, rendered from the assessment.
///
/// The copy rule, and the last part of it is a finding rather than a preference: name the
/// account, name the time in the user's own format, and **never quote a probability**.
/// Fernandes, Walls, Munson, Hullman & Kay (CHI 2018) measured incentivised decision quality
/// across uncertainty encodings and found textual uncertainty the worst-performing one, and
/// sensitive to which interval was communicated. The band is for seeing; the sentence is for
/// deciding.
///
/// This is the one part of the brain that lives in Core, because it is the one part that
/// needs the string catalog. Everything it reads is a value; it holds no state and asks
/// nothing of the app.
public nonisolated enum AssessmentSentences {
    // MARK: - The row's right-hand text

    /// The number that is **not** already on the row.
    public static func rowDetail(_ forecast: WindowForecast, now: Date, style: SentenceStyle = SentenceStyle()) -> String {
        switch forecast.verdict {
        case .spent:
            return qfLocalized(
                "row.spent",
                defaultValue: "Spent",
                comment: "Right-hand text of a quota row whose window is fully used."
            )
        case .runningOut(let at):
            guard let at else { break }
            return qfLocalized(
                "row.limitAt",
                defaultValue: "Limit at \(clock(at, style: style))",
                comment: "Right-hand text of a quota row projected to reach its limit. The argument is a clock time."
            )
        case .silent(let silence):
            switch silence {
            case .learningYourPattern:
                return qfLocalized(
                    "row.learning",
                    defaultValue: "Learning your pattern",
                    comment: "Right-hand text of a quota row with too little history to project from."
                )
            case .noResetInstant:
                return qfLocalized(
                    "row.noReset",
                    defaultValue: "No reset time reported",
                    comment: "Right-hand text of a quota row whose provider named no reset instant."
                )
            case .notStarted:
                let countdown = ResetCountdown.make(
                    resetsAt: forecast.resetsAt,
                    now: now,
                    locale: style.locale,
                    calendar: style.calendar,
                    timeZone: style.timeZone
                )
                return qfLocalized(
                    "row.notStarted",
                    defaultValue: "Not started · resets in \(countdown.visible)",
                    comment: "Right-hand text of a quota row nothing has been spent in. The argument is a countdown."
                )
            case .readingIsStale(let observedAt):
                let countdown = ResetCountdown.make(
                    resetsAt: now,
                    now: observedAt,
                    locale: style.locale,
                    calendar: style.calendar,
                    timeZone: style.timeZone
                )
                return qfLocalized(
                    "row.stale",
                    defaultValue: "\(whole(forecast.usedPercent))% · \(countdown.visible) ago",
                    comment: "Right-hand text of a quota row whose reading is old. A whole percentage and how long ago it was true."
                )
            case .tooEarlyToSay:
                return qfLocalized(
                    "row.tooEarly",
                    defaultValue: "Too early to say",
                    comment: "Right-hand text of a quota row whose projected range is too wide to name a number inside."
                )
            }
        case .onCourse, .cuttingItClose:
            break
        }

        guard let headroom = forecast.landingHeadroomPercent else { return "" }
        if forecast.verdict == .cuttingItClose {
            return qfLocalized(
                "row.spare",
                defaultValue: "~\(whole(headroom))% spare",
                comment: "Right-hand text of a quota row projected to finish its window with little to spare."
            )
        }
        return qfLocalized(
            "row.leftAtReset",
            defaultValue: "~\(whole(headroom))% left at reset",
            comment: "Right-hand text of a quota row projected to finish its window comfortably."
        )
    }

    // MARK: - Spelling

    /// Rounded to a whole number, because the input is quantised to whole percentage points
    /// and a decimal on a projection would be a decoration.
    static func whole(_ percent: Double) -> Int {
        guard percent.isFinite else { return 0 }
        return Int(max(0, min(100, percent)).rounded())
    }

    static func clock(_ date: Date, style: SentenceStyle) -> String {
        date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: style.locale, calendar: style.calendar, timeZone: style.timeZone)
        )
    }
}

// MARK: - The file

nonisolated extension AssessmentSentences {
    /// Everything `recommendation.json` needs a person's language for.
    ///
    /// The words are Core's — they go through `qfLocalized` and a string catalog, and neither
    /// belongs in a target a widget extension links. So they are rendered once, here, and
    /// written into the file; `qota status` prints what the panel's rows say without linking
    /// a line of policy.
    public static func recommendation(_ assessment: FleetAssessment) -> RecommendationSentences {
        let style = SentenceStyle()
        return RecommendationSentences(
            rows: assessment.accounts.flatMap { account in
                account.windows.map { window in
                    RecommendationRowText(
                        account: account.id,
                        windowKey: window.windowKey,
                        text: rowDetail(window, now: assessment.generatedAt, style: style)
                    )
                }
            }
        )
    }
}
