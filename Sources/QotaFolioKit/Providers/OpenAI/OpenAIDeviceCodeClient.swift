import Foundation
import QotaFolioCore

private nonisolated enum OpenAIRequestConstructionError: Error, Sendable {
    case invalidURL
}

private nonisolated struct OpenAIClientIDRequestDTO: Encodable, Sendable {
    let client_id: String
}

nonisolated struct OpenAIDevicePollRequestDTO: Encodable, Sendable {   // module-internal, not file-private: the redaction suite executes the four printing paths against a populated instance of this type
    let device_auth_id: SecretString
    let user_code: String
}

nonisolated struct OpenAIDeviceCodeClient: Sendable {
    nonisolated struct Start: Sendable {
        let deviceAuthID: SecretString
        let userCode: String   // deliberately displayable — the user reads this code aloud to the provider; see OpenAIDeviceFlowDTO
        let interval: Duration
        /// When the server says the code stops working, when it said. The caller bounds its
        /// own polling with `OpenAIWire.deviceDeadline` only when this is absent.
        let expiresAt: Date?
    }

    nonisolated enum PollStep: Sendable {
        case pending
        case slowDown
        case authorized(OpenAIDevicePollDTO)
    }

    private let transport: any HTTPTransport
    private let clock: any MonotonicClock
    private let now: @Sendable () -> Date
    private let log: any RedactingLog

    init(
        transport: any HTTPTransport,
        clock: any MonotonicClock,
        now: @escaping @Sendable () -> Date,
        log: any RedactingLog
    ) {
        self.transport = transport
        self.clock = clock
        self.now = now
        self.log = log
    }

    func usercode() async throws -> Start {
        let request: URLRequest
        do {
            request = try Self.jsonRequest(
                urlString: OpenAIWire.deviceUsercodeURL,
                body: OpenAIClientIDRequestDTO(client_id: OpenAIWire.clientID)
            )
        } catch {
            throw OAuthLoginError.startFailed(.transport)
        }

        try Task.checkCancellation()
        let started = clock.now

        do {
            let response = try await transport.send(
                request,
                maxResponseBytes: CREDENTIAL_POST_MAX_BYTES
            )
            try Task.checkCancellation()

            let body = response.0
            let http = response.1
            switch http.statusCode {
            case 200:
                guard
                    let dto = try? JSONDecoder().decode(OpenAIDeviceUsercodeDTO.self, from: body),
                    let deviceAuthID = dto.deviceAuthID,
                    !deviceAuthID.isEmpty,
                    let userCode = dto.userCode,
                    !userCode.isEmpty,
                    let interval = dto.interval,
                    interval.isFinite,
                    interval > 0,
                    interval <= Double(Int64.max)
                else {
                    emit(
                        operation: .deviceAuthStart,
                        outcome: .transient,
                        host: OpenAIWire.authHost,
                        path: OpenAIWire.deviceUsercodePath,
                        started: started,
                        response: response
                    )
                    throw OAuthLoginError.startFailed(.transport)
                }

                emit(
                    operation: .deviceAuthStart,
                    outcome: .ok,
                    host: OpenAIWire.authHost,
                    path: OpenAIWire.deviceUsercodePath,
                    started: started,
                    response: response
                )
                return Start(
                    deviceAuthID: deviceAuthID,
                    userCode: userCode,
                    interval: .seconds(interval),
                    expiresAt: dto.expiresAt
                )

            case 404:
                emit(
                    operation: .deviceAuthStart,
                    outcome: .permanent,
                    host: OpenAIWire.authHost,
                    path: OpenAIWire.deviceUsercodePath,
                    started: started,
                    response: response
                )
                throw OAuthLoginError.startFailed(.unavailable)

            case 429:
                emit(
                    operation: .deviceAuthStart,
                    outcome: .transient,
                    host: OpenAIWire.authHost,
                    path: OpenAIWire.deviceUsercodePath,
                    started: started,
                    response: response
                )
                // The deadline the provider imposed, fixed HERE, at the one moment the response and the clock are both in
                // hand. Everything downstream carries this instant unchanged; no consumer recomputes it or re-anchors it.
                let retryAt = RetryAfter.parse(
                    http.value(forHTTPHeaderField: "Retry-After"),
                    now: now()
                ).map { clock.now.advanced(by: $0) }
                throw OAuthLoginError.startFailed(.rateLimited(retryAt: retryAt))

            default:
                emit(
                    operation: .deviceAuthStart,
                    outcome: .transient,
                    host: OpenAIWire.authHost,
                    path: OpenAIWire.deviceUsercodePath,
                    started: started,
                    response: response
                )
                throw OAuthLoginError.startFailed(.transport)
            }
        } catch let error as CancellationError {
            throw error
        } catch let error as OAuthLoginError {
            throw error
        } catch is HTTPTransportError {
            try Task.checkCancellation()
            emit(
                operation: .deviceAuthStart,
                outcome: .transient,
                host: OpenAIWire.authHost,
                path: OpenAIWire.deviceUsercodePath,
                started: started
            )
            throw OAuthLoginError.startFailed(.transport)
        } catch {
            try Task.checkCancellation()
            emit(
                operation: .deviceAuthStart,
                outcome: .transient,
                host: OpenAIWire.authHost,
                path: OpenAIWire.deviceUsercodePath,
                started: started
            )
            throw OAuthLoginError.startFailed(.transport)
        }
    }

    func poll(_ start: Start) async throws -> PollStep {
        let request: URLRequest
        do {
            request = try Self.jsonRequest(
                urlString: OpenAIWire.devicePollURL,
                body: OpenAIDevicePollRequestDTO(
                    device_auth_id: start.deviceAuthID,
                    user_code: start.userCode
                )
            )
        } catch {
            throw OAuthLoginError.startFailed(.transport)
        }

        try Task.checkCancellation()
        let started = clock.now

        do {
            let response = try await transport.send(
                request,
                maxResponseBytes: CREDENTIAL_POST_MAX_BYTES
            )
            try Task.checkCancellation()

            let body = response.0
            let http = response.1
            switch http.statusCode {
            case 200:
                guard
                    let dto = try? JSONDecoder().decode(OpenAIDevicePollDTO.self, from: body),
                    let authorizationCode = dto.authorizationCode,
                    !authorizationCode.isEmpty,
                    let codeChallenge = dto.codeChallenge,
                    !codeChallenge.isEmpty,
                    let codeVerifier = dto.codeVerifier,
                    !codeVerifier.isEmpty
                else {
                    emit(
                        operation: .deviceAuthPoll,
                        outcome: .permanent,
                        host: OpenAIWire.authHost,
                        path: OpenAIWire.devicePollPath,
                        started: started,
                        response: response
                    )
                    throw OAuthLoginError.startFailed(.transport)
                }

                emit(
                    operation: .deviceAuthPoll,
                    outcome: .ok,
                    host: OpenAIWire.authHost,
                    path: OpenAIWire.devicePollPath,
                    started: started,
                    response: response
                )
                return .authorized(dto)

            case 403, 404:
                emit(
                    operation: .deviceAuthPoll,
                    outcome: .transient,
                    host: OpenAIWire.authHost,
                    path: OpenAIWire.devicePollPath,
                    started: started,
                    response: response
                )
                return .pending

            case 429:
                emit(
                    operation: .deviceAuthPoll,
                    outcome: .transient,
                    host: OpenAIWire.authHost,
                    path: OpenAIWire.devicePollPath,
                    started: started,
                    response: response
                )
                return .slowDown

            default:
                emit(
                    operation: .deviceAuthPoll,
                    outcome: .permanent,
                    host: OpenAIWire.authHost,
                    path: OpenAIWire.devicePollPath,
                    started: started,
                    response: response
                )
                throw OAuthLoginError.startFailed(.transport)
            }
        } catch let error as CancellationError {
            throw error
        } catch let error as OAuthLoginError {
            throw error
        } catch let error as HTTPTransportError {
            try Task.checkCancellation()
            emit(
                operation: .deviceAuthPoll,
                outcome: .transient,
                host: OpenAIWire.authHost,
                path: OpenAIWire.devicePollPath,
                started: started
            )
            if case .responseTooLarge = error {
                return .pending
            }
            throw OAuthLoginError.startFailed(.transport)
        } catch {
            try Task.checkCancellation()
            emit(
                operation: .deviceAuthPoll,
                outcome: .transient,
                host: OpenAIWire.authHost,
                path: OpenAIWire.devicePollPath,
                started: started
            )
            throw OAuthLoginError.startFailed(.transport)
        }
    }

    func exchange(_ payload: OpenAIDevicePollDTO) async throws -> OAuthTokenSet {
        guard
            let authorizationCode = payload.authorizationCode,
            !authorizationCode.isEmpty,
            let codeChallenge = payload.codeChallenge,
            !codeChallenge.isEmpty,
            let codeVerifier = payload.codeVerifier,
            !codeVerifier.isEmpty
        else {
            throw OAuthLoginError.exchangeFailed
        }
        _ = codeChallenge

        var request: URLRequest
        do {
            request = try Self.formRequest(urlString: OpenAIWire.tokenURL)
        } catch {
            throw OAuthLoginError.exchangeFailed
        }
        // Both halves of the grant are unwrapped only inside this nested scope, and only to be
        // encoded into the form body. Neither raw value outlives the assignment.
        authorizationCode.withUnsafeRawValue { rawCode in
            codeVerifier.withUnsafeRawValue { rawVerifier in
                request.httpBody = Self.formBody([
                    ("grant_type", "authorization_code"),
                    ("code", rawCode),
                    ("redirect_uri", OpenAIWire.exchangeRedirectURI),
                    ("client_id", OpenAIWire.clientID),
                    ("code_verifier", rawVerifier),
                ])
            }
        }

        try Task.checkCancellation()
        let started = clock.now

        do {
            let response = try await transport.send(
                request,
                maxResponseBytes: CREDENTIAL_POST_MAX_BYTES
            )
            try Task.checkCancellation()

            guard response.1.statusCode == 200 else {
                emit(
                    operation: .exchange,
                    outcome: .permanent,
                    host: OpenAIWire.authHost,
                    path: OpenAIWire.tokenPath,
                    started: started,
                    response: response
                )
                throw OAuthLoginError.exchangeFailed
            }
            guard let tokens = OpenAILoginTokenDecoder.decodeLoginTokens(body: response.0) else {
                emit(
                    operation: .exchange,
                    outcome: .permanent,
                    host: OpenAIWire.authHost,
                    path: OpenAIWire.tokenPath,
                    started: started,
                    response: response
                )
                throw OAuthLoginError.exchangeFailed
            }

            emit(
                operation: .exchange,
                outcome: .ok,
                host: OpenAIWire.authHost,
                path: OpenAIWire.tokenPath,
                started: started,
                response: response
            )
            return tokens
        } catch let error as CancellationError {
            throw error
        } catch let error as OAuthLoginError {
            throw error
        } catch is HTTPTransportError {
            try Task.checkCancellation()
            emit(
                operation: .exchange,
                outcome: .transient,
                host: OpenAIWire.authHost,
                path: OpenAIWire.tokenPath,
                started: started
            )
            throw OAuthLoginError.exchangeFailed
        } catch {
            try Task.checkCancellation()
            emit(
                operation: .exchange,
                outcome: .transient,
                host: OpenAIWire.authHost,
                path: OpenAIWire.tokenPath,
                started: started
            )
            throw OAuthLoginError.exchangeFailed
        }
    }

    private func emit(
        operation: DiagOperation,
        outcome: DiagOutcome,
        host: StaticString,
        path: StaticString,
        started: ContinuousClock.Instant,
        response: (Data, HTTPURLResponse)? = nil
    ) {
        log.emit(
            DiagEvent(
                provider: .openai,
                operation: operation,
                outcome: outcome,
                host: host,
                path: path,
                httpStatus: response?.1.statusCode,
                durationMS: clock.elapsedMS(since: started),
                sizeBucket: response.map { diagnosticSizeBucket(forByteCount: $0.0.count) }
            )
        )
    }

    private static func jsonRequest<Body: Encodable>(
        urlString: String,
        body: Body
    ) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw OpenAIRequestConstructionError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// The secret-free half: URL, method and headers. The body is attached separately, so nothing that
    /// touches a raw credential has to be built through a returning closure.
    private static func formRequest(urlString: String) throws -> URLRequest {
        guard let url = URL(string: urlString) else {
            throw OpenAIRequestConstructionError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        return request
    }

    private static func formBody(_ fields: [(String, String)]) -> Data {
        Data(
            fields
                .map { "\(formEncode($0.0))=\(formEncode($0.1))" }
                .joined(separator: "&")
                .utf8
        )
    }

    private static func formEncode(_ value: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        var result = [UInt8]()
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2A, 0x2D, 0x2E, 0x5F:
                result.append(byte)
            case 0x20:
                result.append(0x2B)
            default:
                result.append(0x25)
                result.append(hexadecimal[Int(byte >> 4)])
                result.append(hexadecimal[Int(byte & 0x0F)])
            }
        }
        return String(decoding: result, as: UTF8.self)
    }
}
