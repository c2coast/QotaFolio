import Foundation
import QotaFolioCore

/// A week of polls behind a fixture fleet, replayed through the app's own trace book and
/// assessed by the app's own brain.
///
/// Nothing here is typed by hand into the instrument: the staircases below are polls, the
/// ledger of completed windows is what `UsageTraceBook` closes from them, and the projection
/// on the open card is `FleetBrain`'s own answer over those books at `now`. A fixture panel
/// therefore shows the real machinery on a synthetic day, not a picture of it.
public nonisolated struct FixtureFleetHistory: Sendable {
    public let traces: UsageTraceBook
    public let snapshots: UsageSnapshotBook
    public let assessment: FleetAssessment

    public init(traces: UsageTraceBook, snapshots: UsageSnapshotBook, assessment: FleetAssessment) {
        self.traces = traces
        self.snapshots = snapshots
        self.assessment = assessment
    }
}

public nonisolated extension FixtureUIScenarios {
    /// The panel's face: four accounts with a day behind each of them, anchored to `now` so
    /// every countdown is live.
    ///
    /// Personal (Anthropic, Max 20x) is mid-session with a week two thirds gone and a scoped
    /// Fable window; Attilus (Anthropic, Pro) is being hammered — 71 % of its session with an
    /// hour and a half to run; Work (ChatGPT, Plus) is on course; Spare (ChatGPT, Pro 20x) is
    /// spent, back in 47 minutes.
    static func panelFace(now: Date = .now) -> FixtureUIScenario {
        let personal = account(index: 1, name: "Personal", provider: .anthropic)
        let attilus = account(index: 2, name: "Attilus", provider: .anthropic)
        let work = account(index: 3, name: "Work", provider: .openai)
        let spare = account(index: 4, name: "Spare", provider: .openai)
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3_600
        let day: TimeInterval = 86_400

        let replay = FixtureReplay(now: now, accounts: [
            FixtureReplay.Account(
                config: personal,
                planName: "Max 20x",
                extraUsage: ExtraUsage(isEnabled: true, monthlyLimit: 150, usedCredits: 12.40, utilization: nil, currency: "GBP"),
                credits: nil,
                weekly: .init(resetsAt: now + 1 * day + 19 * hour, usedNow: 47, usedLastWeekAtClose: 71),
                scoped: [.init(scope: "Fable", usedNow: 8, usedLastWeekAtClose: 14)],
                sessions: [
                    .init(openedAgo: 6 * day + 5 * hour, activeMinutes: 150, close: 58),
                    .init(openedAgo: 6 * day - 1 * hour, activeMinutes: 90, close: 11),
                    .init(openedAgo: 5 * day + 3 * hour, activeMinutes: 60, close: 5),
                    .init(openedAgo: 4 * day + 4 * hour, activeMinutes: 170, close: 34),
                    .init(openedAgo: 3 * day + 2 * hour, activeMinutes: 120, close: 22),
                    .init(openedAgo: 2 * day + 4 * hour, activeMinutes: 200, close: 41),
                    .init(openedAgo: 1 * day + 1 * hour, activeMinutes: 100, close: 19),
                    .init(openedAgo: 141 * minute, activeMinutes: 141, close: 38),
                ]
            ),
            FixtureReplay.Account(
                config: attilus,
                planName: "Pro",
                extraUsage: nil,
                credits: nil,
                weekly: .init(resetsAt: now + 3 * day + 4 * hour, usedNow: 62, usedLastWeekAtClose: 97),
                scoped: [],
                sessions: [
                    .init(openedAgo: 6 * day + 4 * hour, activeMinutes: 220, close: 88),
                    .init(openedAgo: 5 * day - 1 * hour, activeMinutes: 160, close: 64),
                    .init(openedAgo: 4 * day + 4 * hour, activeMinutes: 240, close: 100),
                    .init(openedAgo: 3 * day + 3 * hour, activeMinutes: 120, close: 47),
                    .init(openedAgo: 1 * day + 4 * hour, activeMinutes: 230, close: 92),
                    .init(openedAgo: 202 * minute, activeMinutes: 202, close: 71),
                ]
            ),
            FixtureReplay.Account(
                config: work,
                planName: "Plus",
                extraUsage: nil,
                credits: nil,
                weekly: .init(resetsAt: now + 3 * day + 18 * hour, usedNow: 37, usedLastWeekAtClose: 66),
                scoped: [],
                sessions: [
                    .init(openedAgo: 6 * day + 3 * hour, activeMinutes: 180, close: 61),
                    .init(openedAgo: 5 * day + 4 * hour, activeMinutes: 150, close: 44),
                    .init(openedAgo: 4 * day + 3 * hour, activeMinutes: 210, close: 70),
                    .init(openedAgo: 3 * day + 4 * hour, activeMinutes: 120, close: 38),
                    .init(openedAgo: 1 * day + 3 * hour, activeMinutes: 170, close: 55),
                    .init(openedAgo: 235 * minute, activeMinutes: 235, close: 52),
                ]
            ),
            FixtureReplay.Account(
                config: spare,
                planName: "Pro 20x",
                extraUsage: nil,
                credits: UsageCredits(count: 796, dollars: 31.84),
                weekly: .init(resetsAt: now + 5 * day + 6 * hour, usedNow: 88, usedLastWeekAtClose: 100),
                scoped: [],
                sessions: [
                    .init(openedAgo: 6 * day - 1 * hour, activeMinutes: 200, close: 100),
                    .init(openedAgo: 4 * day - 2 * hour, activeMinutes: 190, close: 100),
                    .init(openedAgo: 2 * day + 2 * hour, activeMinutes: 150, close: 73),
                    .init(openedAgo: 1 * day - 1 * hour, activeMinutes: 200, close: 100),
                    // Spent since 73 minutes ago and flat at 100 since; back in 47 minutes.
                    .init(openedAgo: 253 * minute, activeMinutes: 253, close: 100, spentAfterMinutes: 180),
                ]
            ),
        ])

        let replayed = replay.run()
        let accounts = [personal, attilus, work, spare]
        return FixtureUIScenario(
            accounts: accounts,
            snapshots: replayed.latestSnapshots,
            pollStatus: Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, status(.current, now: now)) }),
            loadState: .loaded,
            recoveryAdvisory: nil,
            activeFlow: nil,
            activeFlowProvider: nil,
            now: now,
            history: replayed.history
        )
    }

    /// One account, connected a quarter of an hour ago.
    ///
    /// A few polls behind it, no completed window behind those, and so no projection: the
    /// instrument draws the level it has and says it is still learning. Every account is in
    /// this state on its first day, and it is the only state in which the chart has a line and
    /// no forecast — which is exactly the state its colours have to hold in.
    static func panelNewAccount(now: Date = .now) -> FixtureUIScenario {
        let fresh = account(index: 1, name: "New account", provider: .anthropic)
        let minute: TimeInterval = 60
        let hour: TimeInterval = 3_600
        let day: TimeInterval = 86_400

        let replayed = FixtureReplay(now: now, accounts: [
            FixtureReplay.Account(
                config: fresh,
                planName: "Max 5x",
                extraUsage: nil,
                credits: nil,
                weekly: .init(resetsAt: now + 6 * day + 2 * hour, usedNow: 5, usedLastWeekAtClose: 0),
                scoped: [],
                sessions: [.init(openedAgo: 13 * minute, activeMinutes: 13, close: 8)]
            ),
        ]).run()

        return FixtureUIScenario(
            accounts: [fresh],
            snapshots: replayed.latestSnapshots,
            pollStatus: [fresh.id: status(.current, now: now)],
            loadState: .loaded,
            recoveryAdvisory: nil,
            activeFlow: nil,
            activeFlowProvider: nil,
            now: now,
            history: replayed.history
        )
    }

    /// The states no ordinary fleet is in all at once: a window with no reset reported and
    /// last-known numbers, an account waiting for its first reading, one that needs sign-in,
    /// and one with a setup issue — beside one whole account.
    static func panelStates(now: Date = .now) -> FixtureUIScenario {
        let personal = account(index: 1, name: "Personal", provider: .anthropic)
        let attilus = account(index: 2, name: "Attilus", provider: .anthropic)
        let work = account(index: 3, name: "Work", provider: .openai)
        let spare = account(index: 4, name: "Spare", provider: .openai, authorization: .needsReauthentication(failedRevision: nil))
        let lab = account(index: 5, name: "Lab", provider: .anthropic)
        let hour: TimeInterval = 3_600
        let day: TimeInterval = 86_400

        let snapshots: [AccountID: UsageSnapshot] = [
            personal.id: UsageSnapshot(
                provider: .anthropic,
                readings: [
                    UsageReading(scope: nil, period: .session, window: UsageWindow(usedPercent: 38, resetsAt: now + 2 * hour + 39 * 60, severity: nil)),
                    UsageReading(scope: nil, period: .weekly, window: UsageWindow(usedPercent: 47, resetsAt: now + 1 * day + 19 * hour, severity: nil)),
                    UsageReading(scope: "Fable", period: .weekly, window: UsageWindow(usedPercent: 8, resetsAt: now + 1 * day + 19 * hour, severity: nil)),
                ],
                planName: "Max 20x",
                fetchedAt: now - 120
            ),
            attilus.id: UsageSnapshot(
                provider: .anthropic,
                readings: [
                    UsageReading(scope: nil, period: .session, window: UsageWindow(usedPercent: 71, resetsAt: now + 1 * hour + 38 * 60, severity: nil)),
                    UsageReading(scope: nil, period: .weekly, window: UsageWindow(usedPercent: 62, resetsAt: nil, severity: nil)),
                ],
                planName: "Pro",
                fetchedAt: now - 52 * 60
            ),
        ]
        return FixtureUIScenario(
            accounts: [personal, attilus, work, spare, lab],
            snapshots: snapshots,
            pollStatus: [
                personal.id: status(.current, now: now),
                attilus.id: status(.stale(.temporarilyUnavailable), now: now, lastSuccessAt: now - 52 * 60),
                work.id: status(.waitingForFirstSnapshot, now: now, lastSuccessAt: nil),
                spare.id: status(.suspendedForReauthentication, now: now, lastSuccessAt: nil),
                lab.id: status(.configurationFailure, now: now, lastSuccessAt: nil),
            ],
            loadState: .loaded,
            recoveryAdvisory: nil,
            activeFlow: nil,
            activeFlowProvider: nil,
            now: now
        )
    }

    private static func account(
        index: Int,
        name: String,
        provider: AccountProvider,
        authorization: AccountAuthorizationState = .connected
    ) -> AccountConfig {
        let id = AccountID(rawValue: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!)
        return AccountConfig(
            id: id,
            name: name,
            provider: provider,
            credentialReference: CredentialReference(accountID: id),
            displayOrder: index - 1,
            authorizationState: authorization
        )
    }

    private static func status(_ phase: AccountPollPhase, now: Date, lastSuccessAt: Date?? = nil) -> AccountPollStatus {
        AccountPollStatus(
            phase: phase,
            isRefreshing: false,
            lastAttemptAt: now,
            lastSuccessAt: lastSuccessAt ?? now.addingTimeInterval(-120),
            nextAttemptAt: now.addingTimeInterval(180)
        )
    }
}

/// Polls, generated the way a poller would have made them, and replayed into the app's books.
nonisolated struct FixtureReplay {
    struct Weekly {
        let resetsAt: Date
        /// Percent used now, the week having opened seven days before it resets.
        let usedNow: Double
        /// What the previous week closed at, so the ledger has a completed weekly occurrence.
        let usedLastWeekAtClose: Double
    }

    struct Scoped {
        let scope: String
        let usedNow: Double
        let usedLastWeekAtClose: Double
    }

    struct Session {
        /// How long before `now` this five-hour occurrence opened.
        let openedAgo: TimeInterval
        /// How long the person worked in it, from its open. The last session runs to `now`.
        let activeMinutes: Int
        /// Percent used when work stopped (or now, for the open session).
        let close: Double
        /// For a spent session: the minute at which it reached 100 and went flat.
        var spentAfterMinutes: Int? = nil
    }

    struct Account {
        let config: AccountConfig
        let planName: String?
        let extraUsage: ExtraUsage?
        let credits: UsageCredits?
        let weekly: Weekly?
        let scoped: [Scoped]
        let sessions: [Session]
    }

    struct Result {
        let history: FixtureFleetHistory
        let latestSnapshots: [AccountID: UsageSnapshot]
    }

    let now: Date
    let accounts: [Account]

    private static let sessionLength: TimeInterval = 5 * 3_600
    private static let weekLength: TimeInterval = 7 * 86_400
    private static let pollSpacing: TimeInterval = 5 * 60

    func run() -> Result {
        var traces = UsageTraceBook()
        var latest: [AccountID: UsageSnapshot] = [:]

        for account in accounts {
            var polls: [(at: Date, snapshot: UsageSnapshot)] = []
            for session in account.sessions {
                let opened = now.addingTimeInterval(-session.openedAgo)
                let resetsAt = opened.addingTimeInterval(Self.sessionLength)
                let count = session.activeMinutes / 5
                for index in 0...count {
                    let at = min(opened.addingTimeInterval(Double(index) * Self.pollSpacing), now)
                    let used = Self.staircase(index: index, count: count, close: session.close, spentAfter: session.spentAfterMinutes.map { $0 / 5 })
                    polls.append((at, snapshot(for: account, at: at, sessionUsed: used, sessionResetsAt: resetsAt)))
                }
            }
            polls.sort { $0.at < $1.at }
            var last: Date?
            for poll in polls where last.map({ poll.at > $0 }) ?? true {
                traces.observe(poll.snapshot, for: account.config.id, at: usageHistoryEpochSeconds(poll.at))
                last = poll.at
            }
            if let final = polls.last?.snapshot {
                latest[account.config.id] = final
            }
        }

        let fleet = accounts.map { FleetAccount(config: $0.config) }
        let snapshots = UsageSnapshotBook(
            accounts: latest.map { PersistedUsageSnapshot(account: $0.key, snapshot: $0.value) }
                .sorted { $0.account.rawValue.uuidString < $1.account.rawValue.uuidString }
        )
        let assessment = FleetBrain.assess(
            fleet: fleet,
            traces: traces,
            snapshots: snapshots,
            now: now,
            timeZone: .autoupdatingCurrent
        )
        return Result(
            history: FixtureFleetHistory(traces: traces, snapshots: snapshots, assessment: assessment),
            latestSnapshots: latest
        )
    }

    /// A staircase from nothing to `close`: most polls flat, a rise every third one, so the
    /// line has the shape a real window has.
    private static func staircase(index: Int, count: Int, close: Double, spentAfter: Int?) -> Double {
        guard count > 0 else { return close }
        if let spentAfter, index >= spentAfter { return 100 }
        let horizon = spentAfter ?? count
        let rises = max(1, horizon / 3)
        let risen = min(rises, (index + 1) / 3)
        let value = close * Double(risen) / Double(rises)
        return min(close, value.rounded())
    }

    private func snapshot(for account: Account, at: Date, sessionUsed: Double, sessionResetsAt: Date) -> UsageSnapshot {
        var readings = [
            UsageReading(scope: nil, period: .session, window: UsageWindow(usedPercent: sessionUsed, resetsAt: sessionResetsAt, severity: nil)),
        ]
        if let weekly = account.weekly {
            let (used, resetsAt) = Self.weeklyReading(at: at, now: now, resetsAt: weekly.resetsAt, usedNow: weekly.usedNow, lastClose: weekly.usedLastWeekAtClose)
            readings.append(UsageReading(scope: nil, period: .weekly, window: UsageWindow(usedPercent: used, resetsAt: resetsAt, severity: nil)))
            for scoped in account.scoped {
                let (scopedUsed, _) = Self.weeklyReading(at: at, now: now, resetsAt: weekly.resetsAt, usedNow: scoped.usedNow, lastClose: scoped.usedLastWeekAtClose)
                readings.append(UsageReading(scope: scoped.scope, period: .weekly, window: UsageWindow(usedPercent: scopedUsed, resetsAt: resetsAt, severity: nil)))
            }
        }
        return UsageSnapshot(
            provider: account.config.provider,
            readings: readings,
            planName: account.planName,
            extraUsage: account.extraUsage,
            credits: account.credits,
            fetchedAt: at
        )
    }

    /// The week's level at one instant: rising linearly through the current occurrence to
    /// `usedNow`, and through the previous one to `lastClose`.
    private static func weeklyReading(at: Date, now: Date, resetsAt: Date, usedNow: Double, lastClose: Double) -> (Double, Date) {
        let opened = resetsAt.addingTimeInterval(-weekLength)
        if at >= opened {
            let fraction = max(0, min(1, at.timeIntervalSince(opened) / max(1, now.timeIntervalSince(opened))))
            return ((usedNow * fraction).rounded(), resetsAt)
        }
        let previousOpened = opened.addingTimeInterval(-weekLength)
        let fraction = max(0, min(1, at.timeIntervalSince(previousOpened) / weekLength))
        return ((lastClose * fraction).rounded(), opened)
    }
}
