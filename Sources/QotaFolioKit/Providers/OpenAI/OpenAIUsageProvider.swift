import Foundation
import QotaFolioCore

public nonisolated struct OpenAIUsageProvider: UsageProvider {
    public let provider: AccountProvider = .openai

    private let transport: any HTTPTransport
    private let core: OpenAIUsageRequestCore

    public init(
        transport: any HTTPTransport,
        now: @escaping @Sendable () -> Date,
        clock: any MonotonicClock,
        log: any RedactingLog
    ) {
        self.transport = transport
        self.core = OpenAIUsageRequestCore(now: now, clock: clock, log: log)
    }

    public func fetchUsage(token: ValidAccessToken) async throws -> UsageSnapshot {
        guard let request = core.makeRequest(token: token) else {
            throw UsageProviderError.configuration
        }

        try Task.checkCancellation()
        let started = core.clock.now

        do {
            let response = try await transport.send(
                request,
                maxResponseBytes: OpenAIWire.usageMaxResponseBytes
            )
            try Task.checkCancellation()
            return try core.snapshot(from: core.map(response: response, started: started))
        } catch let error as CancellationError {
            throw error
        } catch let error as UsageProviderError {
            throw error
        } catch let error as HTTPTransportError {
            try Task.checkCancellation()
            return try core.snapshot(from: core.map(transportError: error, started: started))
        } catch {
            try Task.checkCancellation()
            return try core.snapshot(from: core.mapUnknownFailure(started: started))
        }
    }
}

public nonisolated struct OpenAIProductionUsageProvider: ProductionUsageProvider {
    public let provider: AccountProvider = .openai

    private let transport: AnyCancellableHTTPTransport
    private let core: OpenAIUsageRequestCore

    public init(
        transport: any CancellableHTTPTransport,
        now: @escaping @Sendable () -> Date,
        clock: any MonotonicClock,
        log: any RedactingLog
    ) {
        self.transport = AnyCancellableHTTPTransport(transport)
        self.core = OpenAIUsageRequestCore(now: now, clock: clock, log: log)
    }

    public func startUsageRequest(
        id: UsageRequestID,
        token: ValidAccessToken,
        trigger: PollTrigger
    ) -> CancellableUsageRequest {
        guard !Task.isCancelled else {
            return CancellableUsageRequest(id: id, terminal: .cancelled)
        }
        guard var request = core.makeRequest(token: token) else {
            return CancellableUsageRequest(id: id, terminal: .failure(.configuration))
        }
        // The cadence poll is the only request in this app that recurs whether or not anyone
        // is looking, so it is the only one that has to ask what the network costs.
        ProviderNetworkConstraints.apply(to: &request, trigger: trigger)

        let started = core.clock.now
        let underlying = transport.start(
            request,
            id: id,
            maxResponseBytes: OpenAIWire.usageMaxResponseBytes
        )
        return CancellableUsageRequest(id: underlying.id, underlying: underlying) { result in
            switch result {
            case .response(let body, let response):
                return core.map(response: (body, response), started: started)
            case .failure(let error):
                return core.map(transportError: error, started: started)
            case .cancelled:
                return .cancelled
            }
        }
    }
}

private nonisolated struct OpenAIUsageRequestCore: Sendable {
    let now: @Sendable () -> Date
    let clock: any MonotonicClock
    let log: any RedactingLog

    func makeRequest(token: ValidAccessToken) -> URLRequest? {
        guard
            case .openai(let accessToken, let accountID, _) = token,
            let url = URL(string: OpenAIWire.usageURL)
        else {
            emit(outcome: .refused)
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        accessToken.withUnsafeRawValue {
            request.setValue("Bearer \($0)", forHTTPHeaderField: "Authorization")
        }
        accountID.withUnsafeRawValue {
            request.setValue($0, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func map(
        response: (Data, HTTPURLResponse),
        started: ContinuousClock.Instant
    ) -> UsageRequestResult {
        let body = response.0
        let http = response.1
        guard body.count <= OpenAIWire.usageMaxResponseBytes else {
            emit(outcome: .permanent, started: started, response: response)
            return .failure(.invalidPayload)
        }

        switch http.statusCode {
        case 200:
            let parsed: ParsedUsage
            do {
                parsed = try OpenAIUsageParser.parse(body, fetchedAt: now())
            } catch {
                emit(outcome: .permanent, started: started, response: response)
                return .failure(.invalidPayload)
            }
            emit(
                outcome: .ok,
                started: started,
                response: response,
                schemaFamily: parsed.schemaFamily
            )
            return .success(parsed.snapshot)

        case 201..<300:
            emit(outcome: .permanent, started: started, response: response)
            return .failure(.invalidPayload)

        case 401:
            emit(outcome: .transient, started: started, response: response)
            return .failure(.unauthorized)

        case 429:
            emit(outcome: .transient, started: started, response: response)
            return .failure(.rateLimited(
                retryAfter: RetryAfter.parse(
                    http.value(forHTTPHeaderField: "Retry-After"),
                    now: now()
                )
            ))

        default:
            emit(outcome: .transient, started: started, response: response)
            return .failure(.temporarilyUnavailable)
        }
    }

    func map(
        transportError error: HTTPTransportError,
        started: ContinuousClock.Instant
    ) -> UsageRequestResult {
        switch error {
        case .responseTooLarge:
            emit(outcome: .permanent, started: started)
            return .failure(.invalidPayload)
        case .redirectNotFollowed, .transport, .invalidResponse:
            emit(outcome: .transient, started: started)
            return .failure(.temporarilyUnavailable)
        }
    }

    func mapUnknownFailure(started: ContinuousClock.Instant) -> UsageRequestResult {
        emit(outcome: .transient, started: started)
        return .failure(.temporarilyUnavailable)
    }

    func snapshot(from result: UsageRequestResult) throws -> UsageSnapshot {
        switch result {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
    }

    private func emit(
        outcome: DiagOutcome,
        started: ContinuousClock.Instant? = nil,
        response: (Data, HTTPURLResponse)? = nil,
        schemaFamily: StaticString? = nil
    ) {
        log.emit(
            DiagEvent(
                provider: .openai,
                operation: .usageGET,
                outcome: outcome,
                host: OpenAIWire.usageHost,
                path: OpenAIWire.usagePath,
                httpStatus: response?.1.statusCode,
                durationMS: started.map { clock.elapsedMS(since: $0) },
                sizeBucket: response.map { diagnosticSizeBucket(forByteCount: $0.0.count) },
                schemaFamily: schemaFamily
            )
        )
    }
}
