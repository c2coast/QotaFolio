import Foundation
import QotaFolioCore

private nonisolated enum OpenAIRaceResult<Value: Sendable>: Sendable {
    case operation(Value)
    case deadline
}

nonisolated struct OpenAIPollIteration: Sendable {   // module-internal, not file-private: the redaction suite executes the four printing paths against a populated instance of this type
    let step: OpenAIDeviceCodeClient.PollStep
    let completedAt: ContinuousClock.Instant
}

public nonisolated struct OpenAIOAuthAcquirer: OAuthTokenAcquirer {
    public let provider: AccountProvider = .openai

    private let transport: any HTTPTransport
    private let browser: any BrowserOpening
    private let clock: any MonotonicClock
    private let now: @Sendable () -> Date
    private let log: any RedactingLog

    public init(
        transport: any HTTPTransport,
        browser: any BrowserOpening,
        clock: any MonotonicClock,
        now: @escaping @Sendable () -> Date,
        log: any RedactingLog
    ) {
        self.transport = transport
        self.browser = browser
        self.clock = clock
        self.now = now
        self.log = log
    }

    public func acquireTokens(
        report: @MainActor @Sendable @escaping (AccountFlowPhase) -> Void
    ) async throws -> OAuthTokenSet {
        let client = OpenAIDeviceCodeClient(
            transport: transport,
            clock: clock,
            now: now,
            log: log
        )
        let start = try await client.usercode()
        let issuedAt = clock.now
        let receivedAt = now()
        // The server states its own expiry, so the client honours it instead of running a
        // second, private fifteen-minute timer beside it. Two clocks for one deadline agree
        // only by luck. `OpenAIWire.deviceDeadline` is the bound when the server said nothing.
        let remaining = start.expiresAt.map { $0.timeIntervalSince(receivedAt) }
        let lifetime: Duration = if let remaining, remaining.isFinite, remaining > 0 {
            .seconds(remaining)
        } else {
            OpenAIWire.deviceDeadline
        }
        let deadline = issuedAt.advanced(by: lifetime)
        let displayExpiresAt = start.expiresAt ?? receivedAt.addingTimeInterval(
            Double(OpenAIWire.deviceDeadline.components.seconds)
        )
        guard let verificationURL = URL(string: OpenAIWire.verificationURL) else {
            throw OAuthLoginError.startFailed(.transport)
        }

        await report(
            .openAIAwaitingDevice(
                userCode: start.userCode,
                verificationURL: verificationURL,
                expiresAt: displayExpiresAt
            )
        )
        try Task.checkCancellation()

        let browserResult = try await raceAgainstDeadline(deadline: deadline) {
            await browser.open(verificationURL)
        }
        switch browserResult {
        case .operation:
            break
        case .deadline:
            throw OAuthLoginError.deadlineExpired
        }

        var pollInterval = start.interval
        var nextPollStart = issuedAt.advanced(by: pollInterval)

        while true {
            try Task.checkCancellation()
            let scheduledStart = nextPollStart
            let iteration = try await raceAgainstDeadline(deadline: deadline) {
                try await clock.sleep(until: scheduledStart)
                try Task.checkCancellation()
                let step = try await client.poll(start)
                return OpenAIPollIteration(step: step, completedAt: clock.now)
            }

            switch iteration {
            case .deadline:
                throw OAuthLoginError.deadlineExpired

            case .operation(let completed):
                switch completed.step {
                case .pending:
                    nextPollStart = completed.completedAt.advanced(by: pollInterval)

                case .slowDown:
                    pollInterval += OpenAIWire.slowDownWidening
                    nextPollStart = completed.completedAt.advanced(by: pollInterval)

                case .authorized(let payload):
                    await report(.exchanging)
                    try Task.checkCancellation()
                    return try await client.exchange(payload)
                }
            }
        }
    }

    private func raceAgainstDeadline<Value: Sendable>(
        deadline: ContinuousClock.Instant,
        operation: @Sendable @escaping () async throws -> Value
    ) async throws -> OpenAIRaceResult<Value> {
        try await withThrowingTaskGroup(of: OpenAIRaceResult<Value>.self) { group in
            group.addTask {
                .operation(try await operation())
            }
            group.addTask {
                try await clock.sleep(until: deadline)
                return .deadline
            }

            do {
                guard let first = try await group.next() else {
                    throw OAuthLoginError.deadlineExpired
                }
                group.cancelAll()
                while !group.isEmpty {
                    do {
                        _ = try await group.next()
                    } catch {
                        // The losing child is expected to observe cancellation.
                    }
                }
                try Task.checkCancellation()
                return first
            } catch {
                let winnerError = error
                group.cancelAll()
                while !group.isEmpty {
                    do {
                        _ = try await group.next()
                    } catch {
                        // Drain every child before the winner escapes.
                    }
                }
                try Task.checkCancellation()
                throw winnerError
            }
        }
    }
}
