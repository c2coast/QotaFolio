import Foundation

public nonisolated struct RetryCountdown: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case waiting(remainingSeconds: Int64)
        case eligible
        case unavailable
    }

    /// The instant the gate opens, or nil for a rate limit that named no deadline (immediately eligible).
    /// It arrives already absolute from the client that read the 429, so this type stores it and never derives it.
    public let deadline: ContinuousClock.Instant?

    public init(deadline: ContinuousClock.Instant?) {
        self.deadline = deadline
    }

    public func state(at now: ContinuousClock.Instant) -> State {
        guard let deadline else { return .eligible }
        let remaining = now.duration(to: deadline)
        guard remaining > .zero else { return .eligible }
        guard let remainingSeconds = Self.ceilingWholeSeconds(remaining) else {
            return .unavailable
        }
        return .waiting(remainingSeconds: remainingSeconds)
    }

    public func isEnabled(at now: ContinuousClock.Instant) -> Bool {
        state(at: now) == .eligible
    }

    public func remainingText(at now: ContinuousClock.Instant) -> String? {
        guard case .waiting(let remainingSeconds) = state(at: now) else {
            return nil
        }
        let minutes = remainingSeconds / 60
        let seconds = remainingSeconds % 60
        if minutes > 0 {
            return qfLocalized(
                "auth.retry.minutesSeconds",
                defaultValue: "You can try again in \(minutes)m \(seconds)s",
                comment: "Countdown until a rate-limited sign-in attempt can be retried."
            )
        }
        return qfLocalized(
            "auth.retry.seconds",
            defaultValue: "You can try again in \(seconds)s",
            comment: "Countdown in seconds until a rate-limited sign-in attempt can be retried."
        )
    }

    private static func ceilingWholeSeconds(_ duration: Duration) -> Int64? {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return nil
        }
        guard components.attoseconds > 0 else {
            return components.seconds
        }
        let (rounded, overflow) = components.seconds.addingReportingOverflow(1)
        return overflow ? nil : rounded
    }
}
