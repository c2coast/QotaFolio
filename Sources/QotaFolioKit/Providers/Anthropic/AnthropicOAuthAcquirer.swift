import CryptoKit
import Foundation
import QotaFolioCore

public nonisolated struct AnthropicOAuthAcquirer: OAuthTokenAcquirer {
  public let provider: AccountProvider = .anthropic

  private let transport: any HTTPTransport
  private let makeListener: @Sendable () -> any AnthropicCallbackListening
  private let browser: any BrowserOpening
  private let random: any RandomBytesGenerating
  private let clock: any MonotonicClock
  private let now: @Sendable () -> Date
  private let log: any RedactingLog

  public init(
    transport: any HTTPTransport,
    makeListener: @escaping @Sendable () -> any AnthropicCallbackListening,
    browser: any BrowserOpening,
    random: any RandomBytesGenerating,
    clock: any MonotonicClock,
    now: @escaping @Sendable () -> Date,
    log: any RedactingLog
  ) {
    self.transport = transport
    self.makeListener = makeListener
    self.browser = browser
    self.random = random
    self.clock = clock
    self.now = now
    self.log = log
  }

  public func acquireTokens(
    report: @MainActor @Sendable @escaping (AccountFlowPhase) -> Void
  ) async throws -> OAuthTokenSet {
    let verifierBytes = random.bytes(32)
    let stateBytes = random.bytes(32)
    guard verifierBytes.count == 32, stateBytes.count == 32, verifierBytes != stateBytes else {
      throw OAuthLoginError.exchangeFailed
    }

    let verifier = SecretString(Base64URL.encode(verifierBytes))
    let state = SecretString(Base64URL.encode(stateBytes))
    // The verifier is hashed inside the closure; only the PKCE challenge — which is the digest, not the secret — comes out.
    var challenge = ""
    verifier.withUnsafeRawValue { challenge = Base64URL.encode(Data(SHA256.hash(data: Data($0.utf8)))) }
    let listener = makeListener()

    do {
      let ready: AnthropicListenerReady
      do {
        ready = try await listener.startIPv4Only(expectedState: state)
      } catch is CancellationError {
        await listener.stop()
        throw CancellationError()
      } catch {
        await listener.stop()
        throw OAuthLoginError.listenerUnavailable
      }

      let deadline = readyDeadline(from: clock.now)
      let authorizeURL = try buildAuthorizeURL(
        redirectURI: ready.redirectURI,
        state: state,
        challenge: challenge
      )

      do {
        let opened = try await raceAgainstDeadline(deadline: deadline) {
          await browser.open(authorizeURL)
        }
        guard opened else {
          await listener.stop()
          throw OAuthLoginError.browserOpenFailed
        }
      } catch is DeadlineReached {
        await listener.stop()
        throw OAuthLoginError.deadlineExpired
      } catch is CancellationError {
        await listener.stop()
        throw CancellationError()
      }

      await report(.anthropicWaitingInBrowser(authorizationURL: authorizeURL))

      let callback: AnthropicCallbackOutcome
      do {
        callback = try await raceAgainstDeadline(deadline: deadline) {
          try await listener.awaitCallback()
        }
      } catch is DeadlineReached {
        await listener.stop()
        throw OAuthLoginError.deadlineExpired
      } catch is CancellationError {
        await listener.stop()
        throw CancellationError()
      } catch {
        await listener.stop()
        throw OAuthLoginError.listenerUnavailable
      }

      switch callback {
      case .denied:
        await listener.stop()
        throw OAuthLoginError.denied
      case .authorized(let code):
        await report(.exchanging)
        let exchange = AnthropicAuthCodeExchange(
          transport: transport,
          clock: clock,
          now: now,
          log: log
        )
        do {
          let tokens = try await exchange.exchange(
            code: code,
            state: state,
            verifier: verifier,
            redirectURI: ready.redirectURI
          )
          await listener.stop()
          return tokens
        } catch {
          await listener.stop()
          throw error
        }
      }
    } catch {
      await listener.stop()
      throw error
    }
  }

  private func readyDeadline(
    from start: ContinuousClock.Instant
  ) -> ContinuousClock.Instant {
    start.advanced(by: AnthropicWire.loginDeadline)
  }

  private func buildAuthorizeURL(
    redirectURI: URL,
    state: SecretString,
    challenge: String
  ) throws -> URL {
    guard var components = URLComponents(string: AnthropicWire.authorizeURL) else {
      throw OAuthLoginError.exchangeFailed
    }
    // The raw state exists only inside this closure — it is consumed into the query items, never returned bare.
    state.withUnsafeRawValue { rawState in
      components.queryItems = [
        URLQueryItem(name: "code", value: "true"),
        URLQueryItem(name: "client_id", value: AnthropicWire.clientID),
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
        URLQueryItem(name: "scope", value: AnthropicWire.scope),
        URLQueryItem(name: "code_challenge", value: challenge),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "state", value: rawState),
        // Anthropic's authorize page otherwise grants whichever account the browser is
        // already signed in to, without saying so and without offering a choice. For an app
        // whose whole premise is several accounts, that is the second thing a new user does.
        URLQueryItem(name: "prompt", value: AnthropicWire.authorizePrompt),
      ]
    }
    guard let url = components.url else {
      throw OAuthLoginError.exchangeFailed
    }
    return url
  }

  private func raceAgainstDeadline<Value: Sendable>(
    deadline: ContinuousClock.Instant,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: RaceArm<Value>.self) { group in
      group.addTask {
        .operation(try await operation())
      }
      group.addTask {
        try await clock.sleep(until: deadline)
        return .deadline
      }

      do {
        guard let first = try await group.next() else { throw DeadlineReached() }
        group.cancelAll()
        while !group.isEmpty {
          do {
            _ = try await group.next()
          } catch {
            // The losing child is cancelled and drained. Its error is not the transaction result.
          }
        }
        try Task.checkCancellation()
        switch first {
        case .operation(let value):
          return value
        case .deadline:
          throw DeadlineReached()
        }
      } catch {
        let winnerError = error
        group.cancelAll()
        while !group.isEmpty {
          do {
            _ = try await group.next()
          } catch {
            // Drain all structured children before exposing the winner.
          }
        }
        try Task.checkCancellation()
        throw winnerError
      }
    }
  }
}

private nonisolated enum RaceArm<Value: Sendable>: Sendable {
  case operation(Value)
  case deadline
}

private nonisolated struct DeadlineReached: Error, Sendable {}
