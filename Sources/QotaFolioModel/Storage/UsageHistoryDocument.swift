import Foundation

// The durable shapes. They stand to `UsageSnapshot` exactly as `AccountRecord` stands to
// `AccountConfig`: a separate type that owns what is on the device, so the model the app
// draws from can change without a migration and a field on disk can outlive the model.
//
// Every instant is stored as whole seconds since 1970, as an `Int`. That is nine bytes of
// JSON instead of the eighteen a `Double` reference-date interval encodes to, it reads the
// same in every tool a person would open the file with, and a quota percentage has never
// needed sub-second precision.

// MARK: - Instants

public nonisolated func usageHistoryEpochSeconds(_ date: Date) -> Int {
    // Year 1 to year 9999. A `Date` outside that came from arithmetic that already went
    // wrong; clamping keeps it from becoming an unreadable file.
    let seconds = date.timeIntervalSince1970
    guard seconds.isFinite else { return 0 }
    return Int(max(-62_135_596_800, min(253_402_300_799, seconds.rounded())))
}

public nonisolated func usageHistoryDate(_ epochSeconds: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(epochSeconds))
}

/// A percentage in hundredths of a percent, which is finer than any provider reports and
/// finer than the panel can draw. Clamped to 0…100%: a reading past its own limit tells the
/// verdict engine nothing it does not already know from the reading being at its limit.
public nonisolated func usageBasisPoints(fromPercent percent: Double) -> Int {
    guard percent.isFinite else { return 0 }
    return Int(max(0, min(10_000, (percent * 100).rounded())))
}

public nonisolated func usagePercent(fromBasisPoints basisPoints: Int) -> Double {
    Double(max(0, min(10_000, basisPoints))) / 100
}

// MARK: - Provider vocabulary, as it is stored

/// `UsagePeriod` on disk.
///
/// A separate type because `UsagePeriod` is a model with an associated value and no promise
/// of a stable encoding, and because this one has to survive a provider inventing a window
/// length nobody has seen. `other` carries the length the provider reported, so a monthly
/// limit that ships tomorrow is stored as itself rather than rounded into a category.
public nonisolated enum PersistedUsagePeriod: Codable, Equatable, Sendable {
    case session
    case weekly
    case other(seconds: Double)

    public init(_ period: UsagePeriod) {
        switch period {
        case .session: self = .session
        case .weekly: self = .weekly
        case .other(let seconds): self = .other(seconds: seconds)
        }
    }

    public var period: UsagePeriod {
        switch self {
        case .session: .session
        case .weekly: .weekly
        case .other(let seconds): .other(seconds: seconds)
        }
    }

    /// How long this window runs, for the two decisions that need a length: which sampling
    /// tier it belongs in, and where in the window an occurrence currently sits.
    ///
    /// The two named cases answer with what both providers use today — five hours and seven
    /// days. It is an approximation and it is only ever used as one: no verdict is computed
    /// here, and the reset instant the provider reports is what actually bounds an
    /// occurrence.
    public var approximateSeconds: Double {
        switch self {
        case .session: 5 * 3_600
        case .weekly: 7 * 86_400
        case .other(let seconds): seconds > 0 ? seconds : 7 * 86_400
        }
    }
}

/// `UsageSeverity` on disk. Spelled out rather than synthesised, so the file says
/// `"warning"` and not `{"warning":{}}`.
public nonisolated enum PersistedUsageSeverity: String, Codable, Equatable, Sendable {
    case normal, warning, critical

    public init(_ severity: UsageSeverity) {
        switch severity {
        case .normal: self = .normal
        case .warning: self = .warning
        case .critical: self = .critical
        }
    }

    public var severity: UsageSeverity {
        switch self {
        case .normal: .normal
        case .warning: .warning
        case .critical: .critical
        }
    }
}

public nonisolated struct PersistedUsageReading: Codable, Equatable, Sendable {
    public let scope: String?
    public let period: PersistedUsagePeriod
    public let usedPercent: Double
    public let resetsAt: Int?
    public let severity: PersistedUsageSeverity?

    public init(_ reading: UsageReading) {
        scope = reading.scope.map(UsageHistoryPolicy.bounded)
        period = PersistedUsagePeriod(reading.period)
        usedPercent = reading.window.usedPercent
        resetsAt = reading.window.resetsAt.map(usageHistoryEpochSeconds)
        severity = reading.window.severity.map(PersistedUsageSeverity.init)
    }

    public func makeUsageReading() -> UsageReading {
        UsageReading(
            scope: scope,
            period: period.period,
            window: UsageWindow(
                usedPercent: usedPercent,
                resetsAt: resetsAt.map(usageHistoryDate),
                severity: severity?.severity
            )
        )
    }
}

public nonisolated struct PersistedExtraUsage: Codable, Equatable, Sendable {
    public let isEnabled: Bool
    public let monthlyLimit: Double?
    public let usedCredits: Double
    public let utilization: Double?
    public let currency: String?

    public init(_ extra: ExtraUsage) {
        isEnabled = extra.isEnabled
        monthlyLimit = extra.monthlyLimit
        usedCredits = extra.usedCredits
        utilization = extra.utilization
        currency = extra.currency.map(UsageHistoryPolicy.bounded)
    }

    public func makeExtraUsage() -> ExtraUsage {
        ExtraUsage(
            isEnabled: isEnabled,
            monthlyLimit: monthlyLimit,
            usedCredits: usedCredits,
            utilization: utilization,
            currency: currency
        )
    }
}

public nonisolated struct PersistedUsageCredits: Codable, Equatable, Sendable {
    public let count: Int
    public let dollars: Double?

    public init(_ credits: UsageCredits) {
        count = credits.count
        dollars = credits.dollars
    }

    public func makeUsageCredits() -> UsageCredits {
        UsageCredits(count: count, dollars: dollars)
    }
}

// MARK: - The snapshot book

/// The last successful poll for one account, whole.
///
/// Whole, because the panel draws the whole card: every window the provider reported, the
/// plan name, the overage figures and the credits. A snapshot that carried only percentages
/// would put a card on screen with its plan line missing, which is a different empty card.
public nonisolated struct PersistedUsageSnapshot: Codable, Equatable, Sendable {
    public let account: AccountID
    public let provider: AccountProvider
    /// When the provider's answer was true. This is the number the panel ages: a snapshot
    /// from four hours ago is worth showing, and only if it says it is four hours old.
    public let fetchedAt: Int
    public let planName: String?
    public let readings: [PersistedUsageReading]
    public let extraUsage: PersistedExtraUsage?
    public let credits: PersistedUsageCredits?

    public init(account: AccountID, snapshot: UsageSnapshot) {
        self.account = account
        provider = snapshot.provider
        fetchedAt = usageHistoryEpochSeconds(snapshot.fetchedAt)
        planName = snapshot.planName.map(UsageHistoryPolicy.bounded)
        readings = snapshot.readings
            .prefix(UsageHistoryPolicy.windowsPerAccount)
            .map(PersistedUsageReading.init)
        extraUsage = snapshot.extraUsage.map(PersistedExtraUsage.init)
        credits = snapshot.credits.map(PersistedUsageCredits.init)
    }

    public func makeUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            readings: readings.map { $0.makeUsageReading() },
            planName: planName,
            extraUsage: extraUsage?.makeExtraUsage(),
            credits: credits?.makeUsageCredits(),
            fetchedAt: usageHistoryDate(fetchedAt)
        )
    }
}

public nonisolated struct UsageSnapshotBook: UsageHistoryBookProtocol {
    public let schemaVersion: UInt16
    public private(set) var accounts: [PersistedUsageSnapshot]

    public init(schemaVersion: UInt16 = UsageHistoryCodec.schemaVersion, accounts: [PersistedUsageSnapshot] = []) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
    }

    public mutating func record(_ snapshot: PersistedUsageSnapshot) {
        if let index = accounts.firstIndex(where: { $0.account == snapshot.account }) {
            accounts[index] = snapshot
        } else {
            accounts.append(snapshot)
        }
    }

    public mutating func forget(_ account: AccountID) {
        accounts.removeAll { $0.account == account }
    }

    public func snapshot(for account: AccountID) -> PersistedUsageSnapshot? {
        accounts.first { $0.account == account }
    }

    /// One row per account, and no more accounts than the product allows.
    public var isStructurallySound: Bool {
        accounts.count <= qotaFolioMaximumAccounts
            && Set(accounts.map(\.account)).count == accounts.count
    }
}

// MARK: - The trace book

/// One occurrence of a window that has ended, measured at the poll that saw it end.
///
/// This is the record the verdict engine's second question reads: the median weekly cost of
/// a completed short window. It is stored rather than derived because deriving it means
/// reading a trace across a reset, and the last sample before a reset can be half an hour
/// old — the app polls as slowly as every thirty minutes when nothing is on screen. The
/// figures here come from the two polls that bracket the reset, which is the closest the app
/// will ever stand to the moment itself.
public nonisolated struct CompletedUsageWindow: Codable, Equatable, Sendable {
    /// When this occurrence began: the provider's previous reset instant where one was
    /// known, and otherwise the first poll that saw it.
    public let openedAt: Int
    /// When it ended, as the provider's reset instant said it would.
    public let closedAt: Int
    /// How much of the window had been consumed when it ended, in basis points.
    public let usedBasisPointsAtClose: Int
    /// The account's weekly window, at both ends of this occurrence, in basis points.
    ///
    /// Both are absent when the account has no weekly window, and both are absent when the
    /// weekly window itself reset inside this occurrence — a session that straddles a weekly
    /// reset has no weekly cost that can honestly be stated.
    public let weeklyUsedBasisPointsAtOpen: Int?
    public let weeklyUsedBasisPointsAtClose: Int?

    public var opened: Date { usageHistoryDate(openedAt) }
    public var closed: Date { usageHistoryDate(closedAt) }
    public var usedPercentAtClose: Double { usagePercent(fromBasisPoints: usedBasisPointsAtClose) }

    /// What this occurrence cost the account's week, in percentage points, when that can be
    /// said at all.
    public var weeklyCostPercent: Double? {
        guard let open = weeklyUsedBasisPointsAtOpen,
              let close = weeklyUsedBasisPointsAtClose,
              close >= open else { return nil }
        return usagePercent(fromBasisPoints: close - open)
    }
}

/// The trace of one window: every sample kept for it, and every occurrence of it that has
/// ended.
///
/// The samples are two parallel arrays rather than an array of pairs. A pair carries its two
/// field names in every element; at 768 elements that is 12 KB of the word `"time"`. The
/// arrays are always the same length and `UsageHistoryCodec` refuses a document where they
/// are not, so the shape is checked once at the door rather than trusted everywhere.
///
/// The samples run **across** resets, unbroken. The sawtooth is what a sparkline should
/// draw, and a consumer that wants only the current occurrence filters by `currentOpenedAt`,
/// which is one comparison.
public nonisolated struct UsageWindowTrace: Codable, Equatable, Sendable {
    /// `UsageReading.id` — the provider's scope and the window's length together. This is
    /// what makes a ring belong to a limit rather than to a slot in a payload.
    public let key: String
    /// The provider's own display name for a scoped limit; absent for an account-wide one.
    public let scope: String?
    public let period: PersistedUsagePeriod

    public private(set) var sampleTimes: [Int]
    public private(set) var sampleUsedBasisPoints: [Int]
    public private(set) var completed: [CompletedUsageWindow]

    /// The reset instant of the occurrence now open, as the provider last reported it.
    /// **This is when the occurrence ends.** The provider named it when the occurrence
    /// began, so the app can close the occurrence on its own clock and does not have to
    /// wait to be told.
    public private(set) var currentResetsAt: Int?
    /// When the occurrence now open began.
    public private(set) var currentOpenedAt: Int
    /// The account's weekly used-percent when this occurrence opened, in basis points.
    public private(set) var weeklyUsedBasisPointsAtOpen: Int?
    /// The previous poll's reading, carried because a fall is only visible against it: the
    /// poll that sees an unnamed reset shows the new occurrence's low number, and the drop
    /// from this value is the whole of the evidence.
    public private(set) var lastUsedBasisPoints: Int?
    /// The most this occurrence has been seen to hold, in basis points — and therefore what
    /// it cost when it ends.
    ///
    /// **This is the ledger's honest close, and the reading at the last poll is not.** A
    /// window that expires unused returns to zero without the provider naming a new reset
    /// instant, so the polls after the expiry are readings of the *next* occurrence. Closing
    /// from the last of them writes that number into the occurrence that ended — a five-hour
    /// window that reached 5% recorded as 0.00%, and the ledger that answers "how many
    /// sessions does the week fund" poisoned by it. Consumption
    /// inside one occurrence only rises, so the maximum is the close.
    ///
    /// `nil` in one place only: a file written before this field existed. The next
    /// observation seeds it from the samples the occurrence already holds, which is the
    /// same number, so a file already on disk is corrected rather than restarted.
    public private(set) var occurrenceMaximumUsedBasisPoints: Int?
    /// The last poll that reported this window at all, sampled or not. What decides which
    /// window is evicted when an account reports more than it may keep, and what lets a
    /// window that a provider stopped reporting age out.
    public private(set) var lastObservedAt: Int

    public var samples: [(at: Date, usedPercent: Double)] {
        zip(sampleTimes, sampleUsedBasisPoints).map {
            (at: usageHistoryDate($0), usedPercent: usagePercent(fromBasisPoints: $1))
        }
    }

    /// Where the occurrence now open began and ends, when the provider named an end.
    public var currentOccurrence: (openedAt: Date, resetsAt: Date?) {
        (usageHistoryDate(currentOpenedAt), currentResetsAt.map(usageHistoryDate))
    }

    init(reading: UsageReading, observedAt: Int, weeklyUsedBasisPoints: Int?) {
        let period = PersistedUsagePeriod(reading.period)
        key = UsageHistoryPolicy.windowKey(scope: reading.scope, period: period)
        scope = reading.scope.map(UsageHistoryPolicy.bounded)
        self.period = period
        sampleTimes = []
        sampleUsedBasisPoints = []
        completed = []
        currentResetsAt = reading.window.resetsAt.map(usageHistoryEpochSeconds)
        currentOpenedAt = Self.occurrenceStart(
            resetsAt: currentResetsAt,
            period: period,
            observedAt: observedAt
        )
        weeklyUsedBasisPointsAtOpen = weeklyUsedBasisPoints
        lastUsedBasisPoints = nil
        occurrenceMaximumUsedBasisPoints = nil
        lastObservedAt = observedAt
    }

    /// A window's start, which the app needs before it has watched one begin.
    ///
    /// The verdict engine damps the first tenth of an occurrence, so it needs a start on the
    /// first poll after launch, not one occurrence later. The provider's reset instant minus
    /// the window's length is that start, exactly, whenever a reset instant was reported.
    private static func occurrenceStart(
        resetsAt: Int?,
        period: PersistedUsagePeriod,
        observedAt: Int
    ) -> Int {
        guard let resetsAt else { return observedAt }
        return resetsAt - Int(period.approximateSeconds.rounded())
    }

    /// Records one observation of this window.
    ///
    /// Four things can happen and all four are ordinary:
    ///
    ///  - The occurrence ended. It ended at its own reset instant, or — for a window whose
    ///    end nobody named — at the poll that saw the number fall. It is closed into the
    ///    ledger with the most it ever held, and a new one opens.
    ///  - The clock went backwards. Whatever the cause — a time-server correction, the user
    ///    setting the date — the samples ahead of the new instant describe a future that no
    ///    longer exists. They are dropped, so the series stays strictly increasing and every
    ///    consumer can rely on that without checking.
    ///  - The reading arrived too soon after the last one to be worth keeping. The
    ///    observation still counts for eviction and for the ledger; only the sample is
    ///    skipped.
    ///  - Nothing special. Append, evict what has aged out, evict what is over capacity.
    mutating func observe(
        _ reading: UsageReading,
        at observedAt: Int,
        weeklyUsedBasisPoints: Int?
    ) {
        let reportedResetsAt = reading.window.resetsAt.map(usageHistoryEpochSeconds)
        let used = usageBasisPoints(fromPercent: reading.window.usedPercent)
        seedOccurrenceMaximum()

        switch occurrenceEnd(reportedResetsAt: reportedResetsAt, used: used, at: observedAt) {
        case .ended(let closedAt):
            closeCurrentOccurrence(at: closedAt, weeklyUsedBasisPoints: weeklyUsedBasisPoints)
            openOccurrence(
                after: closedAt,
                reportedResetsAt: reportedResetsAt,
                at: observedAt,
                used: used,
                weeklyUsedBasisPoints: weeklyUsedBasisPoints
            )
        case .superseded(let at):
            openOccurrence(
                after: at,
                reportedResetsAt: reportedResetsAt,
                at: observedAt,
                used: used,
                weeklyUsedBasisPoints: weeklyUsedBasisPoints
            )
        case .continues:
            // The same occurrence, restated. Providers nudge a reset instant by a second or
            // two between polls; take the latest word without treating it as an ending. A
            // one-second forward nudge read as an ending closes the window and writes a phantom
            // row, which is then what the sessions-left estimator reads.
            //
            // An instant already behind this poll is not taken at all. It describes an
            // occurrence that has ended, and adopting it would close the occurrence in hand
            // at the next poll, and the poll after that, one phantom row each time.
            if let reportedResetsAt, reportedResetsAt > observedAt {
                currentResetsAt = reportedResetsAt
            }
            occurrenceMaximumUsedBasisPoints = max(occurrenceMaximumUsedBasisPoints ?? used, used)
        }

        appendSample(at: observedAt, used: used)
        lastUsedBasisPoints = used
        lastObservedAt = max(lastObservedAt, observedAt)
    }

    /// What this poll says about the occurrence in hand.
    nonisolated enum OccurrenceEnding: Equatable {
        /// It ended, at this instant, and the ledger records it.
        case ended(at: Int)
        /// It never was an occurrence — the stretch between two of them — and the ledger
        /// records nothing. A window that expires overnight leaves a gap before the next one
        /// opens; writing that gap down as a completed window would put a five-hour window
        /// of nine hours' length in the ledger, and no reader could tell it from one.
        case superseded(at: Int)
        case continues
    }

    /// When the occurrence in hand ended, and whether it was ever an occurrence.
    ///
    /// **An occurrence ends at its own reset instant.** The provider names that instant when
    /// the occurrence begins, so the app already knows the ending before it happens and does
    /// not have to be told again. Waiting to be told does not work: a window that expires
    /// unused returns to zero without a new `resets_at`, and every poll after the expiry would
    /// be filed against the occurrence that had already ended.
    ///
    /// Two other endings exist and both are proven by the number, not by the clock:
    ///
    ///  - **The number fell.** A window that reports no reset instant is a shape the app
    ///    must still read — `UsageWindow.resetsAt` is optional at the model and at both
    ///    wires — and for it a fall is the only evidence there is. It also catches a window
    ///    that reset earlier than the provider said it would. Five percentage points is well
    ///    past any rounding either provider does and well under any real reset, which
    ///    returns a window to zero.
    ///  - **The provider named a window that begins later than this one did.** A window
    ///    cannot begin twice, so the one in hand is over. This is the dormant stretch
    ///    between two occurrences: the five-hour window expires overnight and the next one
    ///    opens when the person next works, hours later.
    ///
    /// A forward move of a reset instant that is still in the future is on this list nowhere.
    /// It is a restatement.
    func occurrenceEnd(reportedResetsAt: Int?, used: Int, at observedAt: Int) -> OccurrenceEnding {
        if let currentResetsAt, observedAt >= currentResetsAt {
            return .ended(at: currentResetsAt)
        }
        if let lastUsedBasisPoints,
           used + Self.resetFallBasisPoints < lastUsedBasisPoints,
           observedAt - currentOpenedAt >= youngestFallableAge {
            return .ended(at: observedAt)
        }
        if currentResetsAt == nil, let reportedResetsAt {
            let implied = Self.occurrenceStart(
                resetsAt: reportedResetsAt,
                period: period,
                observedAt: observedAt
            )
            if implied > currentOpenedAt { return .superseded(at: min(implied, observedAt)) }
        }
        // An occurrence cannot outlive its own window.
        //
        // Both providers report a fixed instant today, so for both of them this never fires:
        // the reset instant above closes the occurrence first, at the same second. It exists
        // because `reset_at` is not a documented contract at either provider, and because
        // ChatGPT's windows may be rolling — `RateLimitWindowSnapshot` carries `reset_at`
        // beside `reset_after_seconds`, which is the shape of a countdown to a fixed instant,
        // but nothing published says so. A provider whose instant slides forward with the
        // clock would otherwise leave one occurrence open for ever: the ledger would never
        // gain a row, so the app could never learn what a window costs, and a five-hour
        // window would be drawn as one that had been running for days.
        //
        // Whether the ending is written down follows the same rule as every other ending. A
        // window with an end of its own that it reached is an occurrence and is recorded; a
        // stretch with no end named is the gap between two of them and is not.
        let length = Int(period.approximateSeconds.rounded())
        if length > 0, observedAt - currentOpenedAt > length {
            let closedAt = currentOpenedAt + length
            return currentResetsAt == nil ? .superseded(at: closedAt) : .ended(at: closedAt)
        }
        return .continues
    }

    /// How far a reading must fall before a fall is the only explanation, in basis points.
    private static let resetFallBasisPoints = 500

    /// How old an occurrence must be before a fall can be read as its ending.
    ///
    /// An occurrence lasts its window's own length, so it cannot be opened, spent and reset
    /// inside a twentieth of it — fifteen minutes of a five-hour window. A fall that early is
    /// something else: a provider restating a stale number, or a poll landing on the second of
    /// a reset while the old value is still on the wire. Without this, that second poll opens
    /// and closes an occurrence in one step and writes the previous window's close down twice.
    private var youngestFallableAge: Int {
        max(
            Int(UsageHistoryPolicy.pollFloorSeconds),
            Int((period.approximateSeconds / 20).rounded())
        )
    }

    private mutating func openOccurrence(
        after closedAt: Int,
        reportedResetsAt: Int?,
        at observedAt: Int,
        used: Int,
        weeklyUsedBasisPoints: Int?
    ) {
        // The occurrence that follows takes the provider's end only when that end is still
        // ahead of this poll. An end already behind it is the one that just closed, restated
        // — and adopting it would close the new occurrence at the next poll, and the poll
        // after that, one phantom row each time.
        let end = reportedResetsAt.flatMap { $0 > observedAt ? $0 : nil }
        currentResetsAt = end
        let opened = end.map {
            Self.occurrenceStart(resetsAt: $0, period: period, observedAt: observedAt)
        } ?? closedAt
        // Never before the occurrence that just closed. Two occurrences of one window cannot
        // overlap, and every reader downstream reads the ledger as a sequence.
        currentOpenedAt = max(opened, closedAt)
        weeklyUsedBasisPointsAtOpen = weeklyUsedBasisPoints
        occurrenceMaximumUsedBasisPoints = used
    }

    /// Fills in the occurrence maximum for a file written before it was recorded.
    ///
    /// The samples the occurrence already holds are the same measurement, so a history file
    /// already on disk answers correctly from its next poll rather than from its next
    /// occurrence. Runs once: after it, the field is never `nil` again.
    private mutating func seedOccurrenceMaximum() {
        guard occurrenceMaximumUsedBasisPoints == nil else { return }
        var maximum = 0
        for (time, used) in zip(sampleTimes, sampleUsedBasisPoints) where time >= currentOpenedAt {
            maximum = max(maximum, used)
        }
        occurrenceMaximumUsedBasisPoints = maximum
    }

    private mutating func closeCurrentOccurrence(at closedAt: Int, weeklyUsedBasisPoints: Int?) {
        guard let lastUsedBasisPoints else { return }
        // An occurrence with no duration was never open. It happens when two readings arrive
        // stamped with the same second, and when a clock correction lands a poll before the
        // occurrence it belongs to; recording it would put a row in the ledger that no reader
        // could tell from a window somebody spent five hours in.
        guard closedAt > currentOpenedAt else { return }
        let openWeekly = weeklyUsedBasisPointsAtOpen
        let closeWeekly = weeklyUsedBasisPoints
        let weeklyIsUsable = if let openWeekly, let closeWeekly { closeWeekly >= openWeekly } else { false }

        completed.append(
            CompletedUsageWindow(
                openedAt: min(currentOpenedAt, closedAt),
                closedAt: closedAt,
                usedBasisPointsAtClose: max(occurrenceMaximumUsedBasisPoints ?? 0, lastUsedBasisPoints),
                weeklyUsedBasisPointsAtOpen: weeklyIsUsable ? openWeekly : nil,
                weeklyUsedBasisPointsAtClose: weeklyIsUsable ? closeWeekly : nil
            )
        )
        if completed.count > UsageHistoryPolicy.completedWindowCapacity {
            completed.removeFirst(completed.count - UsageHistoryPolicy.completedWindowCapacity)
        }
    }

    private mutating func appendSample(at observedAt: Int, used: Int) {
        if let newest = sampleTimes.last {
            if observedAt < newest {
                // The clock moved back. Drop what is now in the future.
                let keep = sampleTimes.firstIndex { $0 >= observedAt } ?? sampleTimes.count
                sampleTimes.removeSubrange(keep...)
                sampleUsedBasisPoints.removeSubrange(keep...)
            } else {
                let spacing = UsageHistoryPolicy.sampleSpacing(
                    periodSeconds: period.approximateSeconds
                )
                guard Double(observedAt - newest) >= spacing else { return }
            }
        }

        sampleTimes.append(observedAt)
        sampleUsedBasisPoints.append(used)
        evict(newestAt: observedAt)
    }

    private mutating func evict(newestAt: Int) {
        let horizon = UsageHistoryPolicy.sampleHorizon(periodSeconds: period.approximateSeconds)
        let oldestKept = newestAt - Int(horizon.rounded())
        var drop = sampleTimes.firstIndex { $0 >= oldestKept } ?? sampleTimes.count
        drop = max(drop, sampleTimes.count - UsageHistoryPolicy.sampleCapacity)
        guard drop > 0 else { return }
        sampleTimes.removeFirst(drop)
        sampleUsedBasisPoints.removeFirst(drop)
    }

    /// True when the two parallel arrays agree and the series is strictly increasing.
    /// `UsageHistoryCodec` asks this of every window it decodes.
    var isStructurallySound: Bool {
        guard sampleTimes.count == sampleUsedBasisPoints.count,
              sampleTimes.count <= UsageHistoryPolicy.sampleCapacity,
              completed.count <= UsageHistoryPolicy.completedWindowCapacity else { return false }
        return zip(sampleTimes, sampleTimes.dropFirst()).allSatisfy { $0 < $1 }
    }
}

public nonisolated struct AccountUsageTrace: Codable, Equatable, Sendable {
    public let account: AccountID
    public private(set) var windows: [UsageWindowTrace]
    /// The last successful poll for this account. What ages a removed account out of the
    /// file on its own.
    public private(set) var lastRecordedAt: Int

    init(account: AccountID, lastRecordedAt: Int) {
        self.account = account
        windows = []
        self.lastRecordedAt = lastRecordedAt
    }

    public func window(_ key: String) -> UsageWindowTrace? {
        windows.first { $0.key == key }
    }

    mutating func observe(_ snapshot: UsageSnapshot, at observedAt: Int) {
        let weekly = snapshot.weekly.map { usageBasisPoints(fromPercent: $0.usedPercent) }

        for reading in snapshot.readings {
            let key = UsageHistoryPolicy.windowKey(
                scope: reading.scope,
                period: PersistedUsagePeriod(reading.period)
            )
            if let index = windows.firstIndex(where: { $0.key == key }) {
                windows[index].observe(reading, at: observedAt, weeklyUsedBasisPoints: weekly)
            } else {
                var trace = UsageWindowTrace(
                    reading: reading,
                    observedAt: observedAt,
                    weeklyUsedBasisPoints: weekly
                )
                trace.observe(reading, at: observedAt, weeklyUsedBasisPoints: weekly)
                windows.append(trace)
            }
        }

        lastRecordedAt = max(lastRecordedAt, observedAt)
        evictStaleWindows(at: observedAt)
    }

    /// A provider that renames a model-scoped limit is indistinguishable from one that adds
    /// a limit, so both are handled by the same rule: a window nobody has reported for
    /// longer than its own samples are kept for is gone, and if more windows are live than
    /// may be kept, the least recently reported goes first.
    private mutating func evictStaleWindows(at observedAt: Int) {
        windows.removeAll { window in
            let horizon = UsageHistoryPolicy.sampleHorizon(
                periodSeconds: window.period.approximateSeconds
            )
            return Double(observedAt - window.lastObservedAt) > horizon
        }
        guard windows.count > UsageHistoryPolicy.windowsPerAccount else { return }
        let survivors = windows
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.lastObservedAt != rhs.element.lastObservedAt {
                    return lhs.element.lastObservedAt > rhs.element.lastObservedAt
                }
                return lhs.offset < rhs.offset
            }
            .prefix(UsageHistoryPolicy.windowsPerAccount)
            .map(\.offset)
        let kept = Set(survivors)
        windows = windows.enumerated().filter { kept.contains($0.offset) }.map(\.element)
    }

    var isStructurallySound: Bool {
        windows.count <= UsageHistoryPolicy.windowsPerAccount
            && Set(windows.map(\.key)).count == windows.count
            && windows.allSatisfy(\.isStructurallySound)
    }
}

public nonisolated struct UsageTraceBook: UsageHistoryBookProtocol {
    public let schemaVersion: UInt16
    public private(set) var accounts: [AccountUsageTrace]

    public init(schemaVersion: UInt16 = UsageHistoryCodec.schemaVersion, accounts: [AccountUsageTrace] = []) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
    }

    public func trace(for account: AccountID) -> AccountUsageTrace? {
        accounts.first { $0.account == account }
    }

    public mutating func observe(_ snapshot: UsageSnapshot, for account: AccountID, at observedAt: Int) {
        if let index = accounts.firstIndex(where: { $0.account == account }) {
            accounts[index].observe(snapshot, at: observedAt)
        } else {
            var trace = AccountUsageTrace(account: account, lastRecordedAt: observedAt)
            trace.observe(snapshot, at: observedAt)
            accounts.append(trace)
        }
        evictStaleAccounts(at: observedAt)
    }

    public mutating func forget(_ account: AccountID) {
        accounts.removeAll { $0.account == account }
    }

    private mutating func evictStaleAccounts(at observedAt: Int) {
        accounts.removeAll {
            Double(observedAt - $0.lastRecordedAt) > UsageHistoryPolicy.accountHorizon
        }
        guard accounts.count > qotaFolioMaximumAccounts else { return }
        accounts = accounts
            .sorted { $0.lastRecordedAt > $1.lastRecordedAt }
            .prefix(qotaFolioMaximumAccounts)
            .sorted { $0.lastRecordedAt < $1.lastRecordedAt }
    }

    public var isStructurallySound: Bool {
        accounts.count <= qotaFolioMaximumAccounts
            && Set(accounts.map(\.account)).count == accounts.count
            && accounts.allSatisfy(\.isStructurallySound)
    }
}
