import Foundation

public nonisolated enum PollingPolicy {
    public static let hardFloor: Duration = .seconds(180)
    public static let rateLimitFirstBackoff: Duration = .seconds(300)
    public static let rateLimitEscalationNumerator = 3
    public static let rateLimitEscalationDenominator = 2
    public static let rateLimitCap: Duration = .seconds(1_800)
    public static let rateLimitCleanReset: Duration = .seconds(3_600)
    public static let cadenceCeiling: Duration = .seconds(1_800)
    public static let failureBackoffBase: Duration = .seconds(180)
    public static let failureBackoffStreakCap = 16
    public static let manualCompletionLinger: Duration = .seconds(5)
    public static let wakeCoalesce: Duration = .seconds(3)
    public static let usageFlightTimeout: Duration = .seconds(300)

    private static let attosecondsPerSecond = Int128(1_000_000_000_000_000_000)
    private static let maximumDurationAttoseconds =
        Int128(Int64.max) * attosecondsPerSecond + (attosecondsPerSecond - 1)
    private static let minimumDurationAttoseconds =
        Int128(Int64.min) * attosecondsPerSecond - (attosecondsPerSecond - 1)

    static let maximumInstantValue = Duration(
        secondsComponent: Int64.max,
        attosecondsComponent: 999_999_999_999_999_999
    )

    public static func representableDelay(
        _ requested: Duration,
        from instant: PollInstant
    ) -> Duration {
        let requestedAttoseconds = totalAttoseconds(of: requested)
        guard requestedAttoseconds > 0 else { return .zero }

        let availableAttoseconds = max(
            Int128.zero,
            maximumDurationAttoseconds - totalAttoseconds(of: instant.rawValue)
        )
        return duration(
            clampingAttoseconds: min(requestedAttoseconds, availableAttoseconds)
        )
    }

    static func saturatingAdding(
        _ requested: Duration,
        to instant: PollInstant
    ) -> PollInstant {
        let delay = representableDelay(requested, from: instant)
        let total = min(
            maximumDurationAttoseconds,
            totalAttoseconds(of: instant.rawValue) + totalAttoseconds(of: delay)
        )
        return PollInstant(rawValue: duration(clampingAttoseconds: total))
    }

    static func saturatingDuration(
        from start: PollInstant,
        to end: PollInstant
    ) -> Duration {
        duration(
            clampingAttoseconds:
                totalAttoseconds(of: end.rawValue) - totalAttoseconds(of: start.rawValue)
        )
    }

    private static func totalAttoseconds(of duration: Duration) -> Int128 {
        let components = duration.components
        return Int128(components.seconds) * attosecondsPerSecond
            + Int128(components.attoseconds)
    }

    private static func duration(clampingAttoseconds value: Int128) -> Duration {
        let clamped = min(
            max(value, minimumDurationAttoseconds),
            maximumDurationAttoseconds
        )
        let seconds = Int64(truncatingIfNeeded: clamped / attosecondsPerSecond)
        let attoseconds = Int64(truncatingIfNeeded: clamped % attosecondsPerSecond)
        return Duration(
            secondsComponent: seconds,
            attosecondsComponent: attoseconds
        )
    }

    /// The one definition of the consecutive-failure widening curve.
    ///
    /// The engine writes this into the account's failure backoff, and `AdaptiveCadence` reads the
    /// same curve for its scheduled delay. Two layers, one authority: an attention trigger cannot
    /// reach a request that the scheduled cadence would refuse.
    public static func failureBackoff(consecutiveFailures: Int) -> Duration {
        guard consecutiveFailures > 0 else { return .zero }
        let streak = min(consecutiveFailures, failureBackoffStreakCap)
        return min(failureBackoffBase * (1 << (streak - 1)), cadenceCeiling)
    }

    public static func softTTL(_ provider: AccountProvider) -> Duration {
        switch provider {
        case .anthropic:
            .seconds(180)
        case .openai:
            .seconds(300)
        }
    }

    public static func isPollable(_ phase: AccountPollPhase) -> Bool {
        switch phase {
        case .waitingForFirstSnapshot, .current, .stale:
            true
        case .suspendedForReauthentication, .configurationFailure:
            false
        }
    }

    public static func isAttention(_ trigger: PollTrigger) -> Bool {
        switch trigger {
        case .panelOpened, .wake, .networkRestored, .manual, .accountAdded:
            true
        case .scheduled, .contextChanged:
            false
        }
    }

    public static func priority(for trigger: PollTrigger) -> TaskPriority? {
        isAttention(trigger) ? .userInitiated : nil
    }
}

public nonisolated enum PollTrigger: Equatable, Sendable {
    case scheduled
    case panelOpened
    case wake
    case networkRestored
    case manual
    case accountAdded
    case contextChanged
}
