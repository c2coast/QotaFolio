import Foundation

/// One band, at one coverage.
public nonisolated struct ForecastBand: Equatable, Sendable {
    /// The share of outcomes this pair is claimed to hold, or `nil` when no claim is honest
    /// and the pair is a range the eye may read but the words may not quote.
    public let coverage: Double?
    public let lowPercent: Double
    public let highPercent: Double

    public var widthPercent: Double { highPercent - lowPercent }

    public init(coverage: Double?, lowPercent: Double, highPercent: Double) {
        self.coverage = coverage
        self.lowPercent = lowPercent
        self.highPercent = highPercent
    }
}

/// Why the instrument said nothing. These five cases, and nothing else belongs here.
///
/// Silence is a feature and it is specified as tightly as the speech. These are the five
/// cases in which nobody could answer, and in every one of them the row still shows a level
/// and a reset — it withholds the projection, not the reading.
public nonisolated enum WindowSilence: Equatable, Sendable {
    /// Nothing to blend and nothing to project.
    case learningYourPattern
    /// The provider named no reset instant, so there is no end to project to.
    case noResetInstant
    /// Nothing has been spent, so there is no elapsed consumption to divide.
    case notStarted
    /// The projection would be about a past that has moved.
    case readingIsStale(observedAt: Date)
    /// The band is wider than sixty percentage points. An honest instrument is allowed to
    /// draw a range and refuse to name a number inside it.
    case tooEarlyToSay
}

/// Where a window is going, in four words.
///
/// The asymmetry is deliberate and it is the whole design: **bad news is raised on the point
/// estimate, good news is granted only on the upper edge.** An account is called on course
/// only when even the pessimistic path lands with ten points to spare. A false "on course"
/// costs the user a blocked afternoon; a false "cutting it close" costs a glance.
public nonisolated enum WindowVerdict: Equatable, Sendable {
    case onCourse
    case cuttingItClose
    /// The projected path reaches the limit, at this instant when one can be named.
    case runningOut(at: Date?)
    case spent
    case silent(WindowSilence)

    public var isSilent: Bool { if case .silent = self { true } else { false } }

    /// The word `recommendation.json` writes. A reader outside this app matches on it, so it
    /// is spelled once, here, and never derived from a case name.
    public var name: String {
        switch self {
        case .onCourse: "onCourse"
        case .cuttingItClose: "cuttingItClose"
        case .runningOut: "runningOut"
        case .spent: "spent"
        case .silent: "silent"
        }
    }

    public var silenceName: String? {
        guard case .silent(let silence) = self else { return nil }
        switch silence {
        case .learningYourPattern: return "learningYourPattern"
        case .noResetInstant: return "noResetInstant"
        case .notStarted: return "notStarted"
        case .readingIsStale: return "readingIsStale"
        case .tooEarlyToSay: return "tooEarlyToSay"
        }
    }

    public var limitInstant: Date? {
        guard case .runningOut(let at) = self else { return nil }
        return at
    }
}

/// What the forecast rests on. The tooltip's material, and the reason a number can be
/// argued with rather than only believed.
public nonisolated struct ForecastEvidence: Equatable, Sendable {
    /// Hours of this occurrence the app watched the person working.
    public let activeHours: Double
    /// Usable completed occurrences behind the prior.
    public let completedWindows: Int
    /// `Z` — how much of the answer is this window's own evidence rather than the ledger's.
    public let credibility: Double
    /// Percentage points per working hour, measured in this occurrence.
    public let ratePerActiveHour: Double?
    /// `Â(now, reset)` — expected working hours between now and the reset.
    public let expectedActiveHoursRemaining: Double
    /// The same hours, discounted: what the app was willing to extrapolate to. Everything a
    /// person reads about this window — the landing, the count of sessions there is time
    /// for — is this number times the rate above.
    public let discountedActiveHoursRemaining: Double
    /// Gardner & McKenzie's φ, which rises with evidence. Carried so the fleet's forward walk
    /// discounts at the same curve the landing was named with.
    public let damping: Double
    /// How far through the occurrence the clock has run, 0…1.
    public let elapsedFraction: Double
    /// The longest recent gap between two polls. What the band's width is floored on.
    public let longestRecentPollGap: TimeInterval
    /// When this window was last reported.
    public let observedAt: Date

    public init(
        activeHours: Double,
        completedWindows: Int,
        credibility: Double,
        ratePerActiveHour: Double?,
        expectedActiveHoursRemaining: Double,
        discountedActiveHoursRemaining: Double = 0,
        damping: Double = 1,
        elapsedFraction: Double,
        longestRecentPollGap: TimeInterval,
        observedAt: Date
    ) {
        self.activeHours = activeHours
        self.completedWindows = completedWindows
        self.credibility = credibility
        self.ratePerActiveHour = ratePerActiveHour
        self.expectedActiveHoursRemaining = expectedActiveHoursRemaining
        self.discountedActiveHoursRemaining = discountedActiveHoursRemaining
        self.damping = damping
        self.elapsedFraction = elapsedFraction
        self.longestRecentPollGap = longestRecentPollGap
        self.observedAt = observedAt
    }
}

/// **The one number, and how sure the app is of it.**
///
/// Everything on screen is a projection of this object at a different size: it draws the bar
/// on a card, it fills the wedge on the runway, and it ranks the fleet.
///
/// `landing` is the **mode** — the single most likely outcome — and not the mean or the
/// median, because the distribution is skewed: consumption is bounded at 100% and piles up
/// near the limit, so the three are three different numbers and the picture has to say which
/// one it draws. It is `nil` in exactly one case: the band came out wider than sixty points,
/// and a number inside an interval that wide would be a decoration.
public nonisolated struct WindowForecast: Equatable, Sendable, Identifiable {
    /// `UsageReading.id` — the provider's own name for the limit and its length.
    public let windowKey: String
    /// The provider's display name for a scoped limit; `nil` for an account-wide one.
    public let scope: String?
    public let period: UsagePeriod
    public var id: String { windowKey }

    /// What is spent now. The only part of this object that is a fact.
    public let usedPercent: Double
    public let resetsAt: Date?
    public let occurrenceOpenedAt: Date

    /// Percent used at the reset instant — the mode.
    public let landingPercent: Double?
    /// Graded, widest last. Empty when nothing may be drawn.
    public let bands: [ForecastBand]
    /// The coverage the words may quote: 0.80, 0.90, 0.95, or `nil` when no honest claim
    /// exists.
    public let coverageClaimed: Double?
    public let verdict: WindowVerdict
    public let evidence: ForecastEvidence

    /// The widest band drawn — the pair the row's range reads from.
    public var outerBand: ForecastBand? { bands.last }

    /// What remains at the reset if the projection holds.
    public var landingHeadroomPercent: Double? { landingPercent.map { max(0, 100 - $0) } }

    public init(
        windowKey: String,
        scope: String?,
        period: UsagePeriod,
        usedPercent: Double,
        resetsAt: Date?,
        occurrenceOpenedAt: Date,
        landingPercent: Double?,
        bands: [ForecastBand],
        coverageClaimed: Double?,
        verdict: WindowVerdict,
        evidence: ForecastEvidence
    ) {
        self.windowKey = windowKey
        self.scope = scope
        self.period = period
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.occurrenceOpenedAt = occurrenceOpenedAt
        self.landingPercent = landingPercent
        self.bands = bands
        self.coverageClaimed = coverageClaimed
        self.verdict = verdict
        self.evidence = evidence
    }
}
