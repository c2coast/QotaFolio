import Foundation

/// **The brain.** One call, on every poll, on the utility queue.
///
/// It reads the two books the app already keeps and answers the question everybody asks and
/// nobody answers: *which account, and for how long.* Neither provider returns history,
/// velocity or a projection — one percentage per window per fetch — so everything here is
/// computed from samples this app took.
///
/// Pure: no clock of its own, no store, no file, no isolation. Every input is an argument and
/// the answer is a value, so the whole of it is testable on recorded data and the same call
/// runs in the app, in a test, and in the terminal command.
public nonisolated struct FleetBrain: FleetAssessing {
    public init() {}

    /// The one call the history writer makes. It runs on the writer actor after every poll,
    /// over books already in memory, and touches no file and no clock of its own.
    public func assess(_ request: FleetAssessmentRequest) -> FleetAssessment {
        Self.assess(
            fleet: request.fleet,
            traces: request.traces,
            snapshots: request.snapshots,
            now: request.now,
            timeZone: request.timeZone
        )
    }

    /// Assesses the fleet.
    ///
    /// - Parameters:
    ///   - fleet: the catalog's rows — id, name, provider, order, authorization state.
    ///   - traces: the sample rings and the completed-window ledger.
    ///   - snapshots: the last successful poll per account, for the figures the rings do not
    ///     carry.
    ///   - now: the instant to answer at.
    ///   - timeZone: the person's own clock. Hour-of-week is a fact about their day.
    public static func assess(
        fleet: [FleetAccount],
        traces: UsageTraceBook,
        snapshots: UsageSnapshotBook = UsageSnapshotBook(),
        now: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> FleetAssessment {
        let ordered = fleet.sorted {
            $0.order == $1.order
                ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                : $0.order < $1.order
        }
        guard !ordered.isEmpty else { return .empty(at: now, timeZone: timeZone) }

        // MARK: One person, one rhythm

        let traceByAccount = Dictionary(
            ordered.compactMap { account in traces.trace(for: account.id).map { (account.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let intervalsByAccount = traceByAccount.mapValues { trace in
            finestWindow(of: trace).map(ObservedInterval.all(in:)) ?? []
        }
        let profile = ActivityProfile.fleet(
            intervals: ordered.compactMap { intervalsByAccount[$0.id] },
            timeZone: timeZone
        )

        // MARK: The fleet as the credibility population

        let ledgers = traceByAccount.mapValues { trace in
            Dictionary(
                trace.windows.map { ($0.key, WindowLedger(window: $0)) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        let (fleetCloses, fleetConstants) = pooled(ledgers: ledgers, traces: traceByAccount)

        // MARK: Each account

        // One horizon for the whole assessment. Every number a person reads about a window is
        // this person's expected working hours, discounted by that window's own damping, times
        // that window's own rate — the forecast, and the count of sessions there is time for.
        // Separate measurements would tell two stories about one week.
        let horizon = profile.horizon(from: now)
        var assessments: [AccountAssessment] = []
        assessments.reserveCapacity(ordered.count)

        for account in ordered {
            let trace = traceByAccount[account.id]
            let snapshot = snapshots.snapshot(for: account.id)
            let windows = trace?.windows ?? []
            let ledgerByKey = ledgers[account.id] ?? [:]
            let sessionWindow = windows.first { $0.scope == nil && $0.period == .session }
            let weeklyWindow = windows.first { $0.scope == nil && $0.period == .weekly }

            let forecasts = windows.map { window -> WindowForecast in
                let ledger = ledgerByKey[window.key] ?? WindowLedger(window: window)
                let group = poolingKey(for: window)
                return WindowForecaster.forecast(
                    window: window,
                    ledger: ledger,
                    context: WindowForecaster.Context(
                        profile: profile,
                        horizon: horizon,
                        fleetClosesNewestFirst: group.flatMap { fleetCloses[$0] } ?? [],
                        fleetCredibilityConstant: group.flatMap { fleetConstants[$0] },
                        now: now
                    )
                )
            }
            .sorted(by: inDrawingOrder)

            // An account polled once, before the first trace reached the device, has a level
            // and a reset and nothing else. It still gets a row: the strip draws it, the
            // panel draws it, and every window on it says which of the five silences it is in
            // rather than nothing at all.
            let forecast = forecasts.isEmpty
                ? (snapshot.map { fromSnapshot($0, now: now) } ?? [])
                : forecasts
            let sessionForecast = forecast.first { $0.scope == nil && $0.period == .session }
            let weeklyForecast = forecast.first { $0.scope == nil && $0.period == .weekly }

            let sessionLedger = sessionWindow.map { ledgerByKey[$0.key] ?? WindowLedger(window: $0) }
                ?? WindowLedger(observations: [])
            let week = WeekPlan.make(
                weekly: weeklyWindow,
                weeklyForecast: weeklyForecast,
                sessionLedger: sessionLedger,
                now: now
            )

            let sessionRemaining = sessionForecast.map { max(0, 100 - $0.usedPercent) }
            let weeklyRemaining = weeklyForecast.map { max(0, 100 - $0.usedPercent) }
            // Below three points — three of the provider's own quantisation steps — a session
            // has nothing spendable in it. An account whose grant has stopped working cannot
            // serve either, whatever its numbers say. It stays on the strip and in the panel.
            let available = (sessionRemaining ?? 100) > BrainPolicy.availableHeadroomPercent
                && (weeklyRemaining ?? 100) > 0
                && account.isConnected
                && !forecast.isEmpty
            // A spent account is back at its session reset. A disconnected one is not coming
            // back on a clock: a grant reopens when the person signs in again, and naming an
            // instant for that would be the app promising something it cannot do.
            let returnsAt = available || !account.isConnected ? nil : sessionForecast?.resetsAt

            assessments.append(
                AccountAssessment(
                    account: account,
                    windows: forecast,
                    weeklyRemainingPercent: weeklyRemaining,
                    sessionRemainingPercent: sessionRemaining,
                    isAvailable: available,
                    returnsAt: returnsAt,
                    week: week,
                    observedAt: trace.map { usageHistoryDate($0.lastRecordedAt) }
                        ?? snapshot.map { usageHistoryDate($0.fetchedAt) }
                )
            )
        }

        let alerts = alerts(for: assessments, now: now)
        return FleetAssessment(
            generatedAt: now,
            accounts: assessments,
            alerts: alerts,
            nextReviewAt: nextReviewAt(accounts: assessments, now: now),
            activity: profile
        )
    }

    // MARK: - The pieces

    /// One row per window of a snapshot, with a level, a reset and no projection.
    ///
    /// The account has been heard from once and the trace has not reached the device yet, so
    /// there is nothing to project from and every window says so. Which of the five silences
    /// it is in is decided by the same rule the forecaster uses, so a row does not change its
    /// mind about why it is quiet the moment a trace arrives.
    static func fromSnapshot(_ snapshot: PersistedUsageSnapshot, now: Date) -> [WindowForecast] {
        let observedAt = usageHistoryDate(snapshot.fetchedAt)
        return snapshot.readings.map { reading in
            let resetsAt = reading.resetsAt.map(usageHistoryDate)
            let opened = resetsAt?.addingTimeInterval(-reading.period.approximateSeconds) ?? observedAt
            let silence = WindowForecaster.silence(
                usedPercent: reading.usedPercent,
                resetsAt: resetsAt,
                observedAt: observedAt,
                now: now,
                activeSeconds: 0,
                completedWindows: 0,
                band: nil
            ) ?? .learningYourPattern
            return WindowForecast(
                windowKey: UsageHistoryPolicy.windowKey(scope: reading.scope, period: reading.period),
                scope: reading.scope,
                period: reading.period.period,
                usedPercent: reading.usedPercent,
                resetsAt: resetsAt,
                occurrenceOpenedAt: opened,
                landingPercent: nil,
                bands: [],
                coverageClaimed: nil,
                verdict: reading.usedPercent >= 100 ? .spent : .silent(silence),
                evidence: ForecastEvidence(
                    activeHours: 0,
                    completedWindows: 0,
                    credibility: 0,
                    ratePerActiveHour: nil,
                    expectedActiveHoursRemaining: 0,
                    elapsedFraction: 0,
                    longestRecentPollGap: 0,
                    observedAt: observedAt
                )
            )
        }
        .sorted(by: inDrawingOrder)
    }

    /// The window whose length is shortest — the one that resolves work most finely, and
    /// therefore the one the activity profile is measured from. Ties go to the account's own
    /// window rather than a model-scoped one.
    static func finestWindow(of trace: AccountUsageTrace) -> UsageWindowTrace? {
        trace.windows.min {
            let left = $0.period.approximateSeconds
            let right = $1.period.approximateSeconds
            if left != right { return left < right }
            return ($0.scope == nil ? 0 : 1) < ($1.scope == nil ? 0 : 1)
        }
    }

    /// Which windows may be pooled across accounts.
    ///
    /// The account's own session and weekly windows are the same measurement at every
    /// account, so they are one credibility population. A model-scoped limit is the
    /// provider's own name for its own thing and two accounts' scoped limits are not
    /// comparable, so those are never pooled and answer from their own history alone.
    static func poolingKey(for window: UsageWindowTrace) -> String? {
        guard window.scope == nil else { return nil }
        return UsageHistoryPolicy.windowKey(scope: nil, period: window.period)
    }

    private static func pooled(
        ledgers: [AccountID: [String: WindowLedger]],
        traces: [AccountID: AccountUsageTrace]
    ) -> (closes: [String: [Double]], constants: [String: Double]) {
        var closesByGroup: [String: [[Double]]] = [:]
        for (account, trace) in traces {
            for window in trace.windows {
                guard let group = poolingKey(for: window) else { continue }
                let ledger = ledgers[account]?[window.key] ?? WindowLedger(window: window)
                let closes = ledger.recentCloses
                guard !closes.isEmpty else { continue }
                closesByGroup[group, default: []].append(closes)
            }
        }

        var closes: [String: [Double]] = [:]
        var constants: [String: Double] = [:]
        for (group, perAccount) in closesByGroup {
            closes[group] = perAccount.flatMap { $0 }
            if let k = LedgerPrior.fleetCredibilityConstant(closesPerAccount: perAccount) {
                constants[group] = k
            }
        }
        return (closes, constants)
    }

    /// The account's own short window, then its weekly, then everything the provider named,
    /// most constrained first. The same order `UsageSnapshot` imposes, so a card and a
    /// forecast list never disagree about which row is which.
    static func inDrawingOrder(_ lhs: WindowForecast, _ rhs: WindowForecast) -> Bool {
        func rank(_ forecast: WindowForecast) -> Int {
            guard forecast.scope == nil else { return 2 }
            return forecast.period == .session ? 0 : 1
        }
        let left = rank(lhs)
        let right = rank(rhs)
        if left != right { return left < right }
        if left == 2, lhs.usedPercent != rhs.usedPercent { return lhs.usedPercent > rhs.usedPercent }
        return lhs.windowKey < rhs.windowKey
    }

    /// The three things worth interrupting somebody for, each with a key that is stable for
    /// as long as the condition is.
    static func alerts(for accounts: [AccountAssessment], now: Date) -> [FleetAlert] {
        var alerts: [FleetAlert] = []

        for assessment in accounts {
            // Information beside the news: another account that is free right now, if one is.
            let alternative = accounts.first { $0.isAvailable && $0.id != assessment.id }?.id
            let occurrence = assessment.windows.first?.occurrenceOpenedAt ?? now
            for window in assessment.windows {
                if case .runningOut(let at) = window.verdict, let at {
                    alerts.append(
                        FleetAlert(
                            kind: .runningOut(
                                at: at,
                                windowKey: window.windowKey,
                                alternative: alternative
                            ),
                            account: assessment.id,
                            key: key("running-out", assessment.id, window.windowKey, window.occurrenceOpenedAt)
                        )
                    )
                }
                let age = now.timeIntervalSince(window.occurrenceOpenedAt)
                if age >= 0, age <= BrainPolicy.alertFreshWindowAge, window.usedPercent < 100 {
                    alerts.append(
                        FleetAlert(
                            kind: .freshWindow(windowKey: window.windowKey, since: window.occurrenceOpenedAt),
                            account: assessment.id,
                            key: key("fresh-window", assessment.id, window.windowKey, window.occurrenceOpenedAt)
                        )
                    )
                }
            }
            // Quota that will expire unused at this pace: the weekly window's own forecast
            // landing, so the alert and the row it sits beside are one measurement and can
            // never name two different numbers for one week.
            if let weekly = assessment.weekly,
               let landing = weekly.landingPercent,
               let expiresAt = weekly.resetsAt {
                let stranded = max(0, min(100, 100 - landing))
                if stranded >= BrainPolicy.alertStrandingPercent {
                    alerts.append(
                        FleetAlert(
                            kind: .stranding(percent: stranded, expiresAt: expiresAt),
                            account: assessment.id,
                            key: key("stranding", assessment.id, "weekly", occurrence)
                        )
                    )
                }
            }
        }
        return alerts
    }

    private static func key(_ condition: String, _ account: AccountID, _ window: String, _ occurrence: Date) -> String {
        "\(condition)|\(account.rawValue.uuidString)|\(window)|\(usageHistoryEpochSeconds(occurrence))"
    }

    /// The earliest instant at which any of this could read differently.
    ///
    /// The store arms its wake on this, so the panel and the strip are right between two
    /// polls: a countdown reaching zero, a reading going stale, and an account coming back
    /// are all changes nobody polls for.
    static func nextReviewAt(accounts: [AccountAssessment], now: Date) -> Date {
        var candidates: [Date] = []
        for assessment in accounts {
            for window in assessment.windows {
                if let resetsAt = window.resetsAt, resetsAt > now { candidates.append(resetsAt) }
                let stale = window.evidence.observedAt.addingTimeInterval(BrainPolicy.silenceStaleReadingAge)
                if stale > now { candidates.append(stale) }
            }
            if let returnsAt = assessment.returnsAt, returnsAt > now { candidates.append(returnsAt) }
        }

        let soonest = candidates.min() ?? now.addingTimeInterval(BrainPolicy.reviewCeiling)
        return min(
            max(soonest, now.addingTimeInterval(BrainPolicy.reviewFloor)),
            now.addingTimeInterval(BrainPolicy.reviewCeiling)
        )
    }
}
