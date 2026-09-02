import Foundation

public nonisolated struct CadenceInput: Equatable, Sendable {
    public let provider: AccountProvider
    public let isPanelVisible: Bool
    public let timeSinceLastPanelOpen: Duration?
    public let isLowPowerModeEnabled: Bool
    public let thermalPressure: ThermalPressure
    public let timeSinceLastRequestStart: Duration?
    public let cacheAge: Duration?
    public let hardNotBefore: Duration
    public let consecutiveFailures: Int
    public let timeUntilEarliestReset: Duration?

    public init(
        provider: AccountProvider,
        isPanelVisible: Bool,
        timeSinceLastPanelOpen: Duration?,
        isLowPowerModeEnabled: Bool,
        thermalPressure: ThermalPressure,
        timeSinceLastRequestStart: Duration?,
        cacheAge: Duration?,
        hardNotBefore: Duration,
        consecutiveFailures: Int,
        timeUntilEarliestReset: Duration?
    ) {
        self.provider = provider
        self.isPanelVisible = isPanelVisible
        self.timeSinceLastPanelOpen = timeSinceLastPanelOpen
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalPressure = thermalPressure
        self.timeSinceLastRequestStart = timeSinceLastRequestStart
        self.cacheAge = cacheAge
        self.hardNotBefore = hardNotBefore
        self.consecutiveFailures = consecutiveFailures
        self.timeUntilEarliestReset = timeUntilEarliestReset
    }
}

public nonisolated struct CadenceDecision: Equatable, Sendable {
    public let delay: Duration
    public let tolerance: Duration
    public let rationale: CadenceRationale

    public init(delay: Duration, tolerance: Duration, rationale: CadenceRationale) {
        self.delay = delay
        self.tolerance = tolerance
        self.rationale = rationale
    }
}

public nonisolated enum ThermalPressure: Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public nonisolated enum CadenceRationale: Equatable, Sendable {
    case nominalTier
    case thermalDoubled
    case constrained30
    case failureWiden(Int)
    case resetTargeted
    case softTTLFloored
    case hardFloorFloored
}

public nonisolated enum AdaptiveCadence {
    public static func decide(_ input: CadenceInput) -> CadenceDecision {
        var delay = nominal(input)
        var rationale = CadenceRationale.nominalTier

        if input.thermalPressure == .fair {
            delay = min(delay * 2, PollingPolicy.cadenceCeiling)
            rationale = .thermalDoubled
        }

        if input.isLowPowerModeEnabled
            || input.thermalPressure == .serious
            || input.thermalPressure == .critical
        {
            delay = PollingPolicy.cadenceCeiling
            rationale = .constrained30
        }

        if input.consecutiveFailures > 0 {
            let clampedStreak = min(
                input.consecutiveFailures,
                PollingPolicy.failureBackoffStreakCap
            )
            let widened = PollingPolicy.failureBackoff(
                consecutiveFailures: input.consecutiveFailures
            )
            if widened > delay {
                delay = widened
                rationale = .failureWiden(clampedStreak)
            }
        }

        if let elapsed = input.timeSinceLastRequestStart {
            delay = max(.zero, delay - elapsed)
        }

        if let untilReset = input.timeUntilEarliestReset, untilReset > .zero {
            let targeted = untilReset + .seconds(15)
            if targeted < delay {
                delay = targeted
                rationale = .resetTargeted
            }
        }

        if delay > PollingPolicy.cadenceCeiling {
            delay = PollingPolicy.cadenceCeiling
        }

        if let age = input.cacheAge {
            let ttlRemaining = max(.zero, PollingPolicy.softTTL(input.provider) - age)
            if ttlRemaining > delay {
                delay = ttlRemaining
                rationale = .softTTLFloored
            }
        }

        if input.hardNotBefore > delay {
            delay = input.hardNotBefore
            rationale = .hardFloorFloored
        }

        return CadenceDecision(
            delay: delay,
            tolerance: tolerance(for: rationale, delay: delay),
            rationale: rationale
        )
    }

    private static func nominal(_ input: CadenceInput) -> Duration {
        if input.isPanelVisible {
            return .seconds(180)
        }

        switch input.timeSinceLastPanelOpen {
        case .some(let elapsed) where elapsed <= .seconds(900):
            return input.provider == .anthropic ? .seconds(180) : .seconds(300)
        case .some(let elapsed) where elapsed <= .seconds(3_600):
            return input.provider == .anthropic ? .seconds(300) : .seconds(600)
        // The product table assigns hidden idle time of >=4 h to the 30-minute tier.
        // Equality therefore belongs to the default arm; only values below 4 h stay at 15 minutes.
        case .some(let elapsed) where elapsed < .seconds(14_400):
            return .seconds(900)
        default:
            return .seconds(1_800)
        }
    }

    private static func tolerance(
        for rationale: CadenceRationale,
        delay: Duration
    ) -> Duration {
        if delay == .zero {
            return .zero
        }

        switch rationale {
        case .resetTargeted:
            // This wake aims just past a known reset instant, so it keeps a tighter ceiling than
            // the ordinary tiers. Five flat seconds on a half-hour deadline would be a strict timer
            // the system could fold into nothing; a minute of leeway is still imperceptible here.
            return min(max(delay / 10, .seconds(15)), .seconds(60))
        case .nominalTier,
             .thermalDoubled,
             .constrained30,
             .failureWiden,
             .softTTLFloored,
             .hardFloorFloored:
            // Ten percent leeway is what lets the system fold several accounts into one wake. A
            // 60-second cap would throw that away above ten minutes, which is exactly where the idle
            // tiers live. Nothing here is time-critical: the number is minutes old by design.
            return min(max(delay / 10, .seconds(15)), .seconds(300))
        }
    }
}
