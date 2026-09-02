import Foundation

public nonisolated struct PollInstant: Comparable, Hashable, Sendable {
    public let rawValue: Duration

    public init(rawValue: Duration) {
        self.rawValue = rawValue
    }

    public static func < (lhs: PollInstant, rhs: PollInstant) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public nonisolated protocol PollClock: Sendable {
    func now() -> PollInstant
    func wallNow() -> Date
    func wallDate(for instant: PollInstant) -> Date
    func sleep(until deadline: PollInstant, tolerance: Duration?) async throws
    func duration(from start: PollInstant, to end: PollInstant) -> Duration
    func adding(_ duration: Duration, to instant: PollInstant) -> PollInstant
}

public nonisolated struct ContinuousPollClock: PollClock {
    private let clock: ContinuousClock
    private let epoch: ContinuousClock.Instant

    public init() {
        let clock = ContinuousClock()
        self.clock = clock
        self.epoch = clock.now
    }

    public func now() -> PollInstant {
        PollInstant(rawValue: epoch.duration(to: clock.now))
    }

    public func wallNow() -> Date {
        Date()
    }

    public func wallDate(for instant: PollInstant) -> Date {
        let wall = wallNow()
        let remaining = duration(from: now(), to: instant)
        return wall.addingProjectedInterval(remaining.wallProjectionTimeIntervalValue)
    }

    public func sleep(until deadline: PollInstant, tolerance: Duration?) async throws {
        while true {
            let remaining = duration(from: now(), to: deadline)
            guard remaining > .zero else { return }
            let chunk = min(remaining, .seconds(2_592_000))
            try await clock.sleep(
                until: clock.now.advanced(by: chunk),
                tolerance: tolerance
            )
        }
    }

    public func duration(from start: PollInstant, to end: PollInstant) -> Duration {
        PollingPolicy.saturatingDuration(from: start, to: end)
    }

    public func adding(_ duration: Duration, to instant: PollInstant) -> PollInstant {
        PollingPolicy.saturatingAdding(duration, to: instant)
    }
}

public nonisolated extension Duration {
    var timeIntervalValue: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }

    var wallProjectionTimeIntervalValue: TimeInterval {
        let components = components
        let wholeSeconds = Double(components.seconds)
        let approximate = wholeSeconds + Double(components.attoseconds) * 1e-18
        guard self > .zero else { return approximate }

        let roundedWholeSeconds = Int128(wholeSeconds)
        let exactWholeSeconds = Int128(components.seconds)
        if roundedWholeSeconds < exactWholeSeconds
            || (roundedWholeSeconds == exactWholeSeconds && components.attoseconds > 0)
        {
            return approximate.nextUp
        }
        return approximate
    }
}

nonisolated extension Date {
    func addingProjectedInterval(_ interval: TimeInterval) -> Date {
        let base = timeIntervalSinceReferenceDate
        var projected = base + interval
        if interval > 0 {
            while projected - base < interval {
                let next = projected.nextUp
                guard next.isFinite, next > projected else { break }
                projected = next
            }
        }
        return Date(timeIntervalSinceReferenceDate: projected)
    }
}
