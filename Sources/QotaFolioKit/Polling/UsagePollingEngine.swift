import Foundation
import QotaFolioCore

/// One attempt to read one account's usage.
///
/// The task owns the whole attempt: the vault read, the GET, the settlement and the report.
/// Cancelling the task cancels the HTTP request with it, because the request is joined through a
/// cancellation handler rather than tracked in a side table. `isSettled` is the one latch that
/// decides the race between the request finishing and its ceiling expiring; whichever arrives
/// first sets it inside a single actor turn, and the loser returns.
nonisolated struct FlightHandle: Sendable {
    let id: UInt64
    let task: Task<Void, Never>
    let timeoutTask: Task<Void, Never>
    var latestGETStartedAt: Date?
    var isSettled: Bool
}

/// Which attempt a result belongs to.
///
/// The flight identifier is minted from one monotonic counter for the whole engine, so a key
/// names at most one flight that will ever exist. `retireFlight` clears `inFlight` and the
/// account's current flight is what `currentState` compares against, so a lineage generation
/// here would be a second latch on a question the first one already answers exactly.
nonisolated struct FlightKey: Sendable {
    let account: AccountID
    let flight: UInt64
}

nonisolated enum FlightOutcome: Sendable {
    case success(snapshot: UsageSnapshot, attemptedAt: Date)
    case providerTagMismatch(attemptedAt: Date)
    case providerFailure(error: UsageProviderError, attemptedAt: Date)
    case vaultFailure(error: TokenVaultError, attemptedAt: Date?)
    case authorizationRejected(revision: CredentialRevision, attemptedAt: Date)
    case temporaryFailure(attemptedAt: Date?)
}

nonisolated struct AccountState {
    var config: AccountConfig
    var cache: (snapshot: UsageSnapshot, at: PollInstant)? = nil
    var lastRequestStartedAt: PollInstant? = nil
    var inFlight: FlightHandle? = nil
    /// Which version of this account the engine is holding, as the store last told it. The
    /// engine never mints one and never bumps one: what an account *is* is the store's
    /// question, and an engine that answered it too would be a second opinion.
    var epoch: UInt64
    /// The server's own instruction after a 429. Never bypassed: a local network change is no
    /// evidence that a provider's rate limit expired.
    var rateLimitBackoffUntil: PollInstant? = nil
    /// The consecutive-failure widening, mirrored from `PollingPolicy.failureBackoff`. Bypassable
    /// exactly once per streak by a genuine network restoration.
    var failureBackoffUntil: PollInstant? = nil
    var networkRestoreBypassSpent: Bool = false
    var rateLimitPenalty: Duration? = nil
    var lastHeaderlessRateLimitAt: PollInstant? = nil
    var consecutiveFailures: Int = 0
    var authorizationRejectedRevision: CredentialRevision? = nil
    var lineageRevision: CredentialRevision? = nil
    var lastAttemptAt: Date? = nil
    var lastSuccessAt: Date? = nil
    var phase: AccountPollPhase

    /// The earliest instant any trigger may start a request, whatever the reason for the wait.
    var backoffUntil: PollInstant? {
        switch (rateLimitBackoffUntil, failureBackoffUntil) {
        case (.some(let rateLimit), .some(let failure)):
            max(rateLimit, failure)
        case (.some(let rateLimit), .none):
            rateLimit
        case (.none, .some(let failure)):
            failure
        case (.none, .none):
            nil
        }
    }
}

nonisolated extension AccountState {
    /// The account after its credentials were replaced. Everything the old lineage earned about
    /// *this account* leaves with it; everything the provider still enforces against the machine
    /// stays. Written as a mutation of the old state so a field added later carries forward
    /// unless someone decides otherwise here.
    static func recreatedForLineageReset(
        from old: AccountState,
        epoch: UInt64,
        lineageRevision: CredentialRevision
    ) -> AccountState {
        var reset = old
        reset.cache = nil
        reset.inFlight = nil
        reset.epoch = epoch
        // The provider's rate limit outlives our credentials; the failure streak does not. The
        // reset declares the old streak irrelevant, so its backoff leaves with it.
        reset.failureBackoffUntil = nil
        reset.networkRestoreBypassSpent = false
        reset.consecutiveFailures = 0
        reset.authorizationRejectedRevision = nil
        reset.lineageRevision = lineageRevision
        reset.lastSuccessAt = nil
        reset.phase = .waitingForFirstSnapshot
        return reset
    }
}

actor UsagePollingEngine: UsagePollingEngineDriving {
    private let clock: any PollClock
    private let vault: any TokenVault
    private let providers: [AccountProvider: any ProductionUsageProvider]
    private weak var reporter: (any PollReporting)?
    private var states: [AccountID: AccountState] = [:]
    /// Shut for the duration of a stop, so a supervisor that was already suspended inside `poll`
    /// cannot commit a fresh request behind the stop's back. Reopened when the stop returns,
    /// because the only way back to polling is a `start` that re-establishes every account.
    private var isStopping = false
    private var nextFlightID: UInt64 = 0

    init(
        clock: any PollClock,
        vault: any TokenVault,
        providers: [AccountProvider: any ProductionUsageProvider]
    ) {
        self.clock = clock
        self.vault = vault
        self.providers = providers
    }

    init(
        clock: any PollClock,
        vault: any TokenVault,
        providers: [AccountProvider: any UsageProvider]
    ) {
        self.clock = clock
        self.vault = vault
        self.providers = providers.mapValues(LegacyUsageProviderAdapter.init)
    }

    func attach(_ reporter: any PollReporting) async {
        self.reporter = reporter
    }

    func reprojectRateLimitWallDates() async {
        guard !isStopping else { return }
        for id in stableIDs() {
            guard !isStopping,
                  var state = states[id],
                  case .stale(.rateLimited(retryAt: _)) = state.phase,
                  let backoffUntil = state.backoffUntil,
                  clock.now() < backoffUntil
            else { continue }

            state.phase = .stale(
                .rateLimited(retryAt: clock.wallDate(for: backoffUntil))
            )
            states[id] = state
            await reporter?.receive(
                report(state, isRefreshing: false, snapshot: .unchanged)
            )
        }
    }

    func poll(
        _ id: AccountID,
        trigger: PollTrigger,
        manualCycle: UInt64?
    ) async {
        await performPoll(
            id,
            trigger: trigger,
            manualCycle: manualCycle,
            activityRunEpoch: nil
        )
    }

    func poll(
        _ id: AccountID,
        trigger: PollTrigger,
        manualCycle: UInt64?,
        activityRunEpoch: UInt64
    ) async {
        await performPoll(
            id,
            trigger: trigger,
            manualCycle: manualCycle,
            activityRunEpoch: activityRunEpoch
        )
    }

    private func performPoll(
        _ id: AccountID,
        trigger: PollTrigger,
        manualCycle: UInt64?,
        activityRunEpoch: UInt64?
    ) async {
        guard !Task.isCancelled, !isStopping else { return }
        guard var state = states[id] else { return }
        guard PollingPolicy.isPollable(state.phase) else {
            await acknowledgeManualIfCurrent(id, cycle: manualCycle)
            return
        }

        // An account has at most one flight, and the flight's own task publishes its settlement.
        // A second caller joins that task rather than starting a rival request.
        //
        // `joinFlight` and not `await flight.task.value`: a bare join neither throws on the
        // joiner's cancellation nor returns early, so a retired supervisor would stay parked
        // here until somebody else's request finished. The flight is left alone — the caller
        // who owns it still wants its answer.
        // `try?` because a flight that cannot fail leaves `CancellationError` as the only thing
        // this can throw, and leaving is exactly what was asked for.
        if let flight = state.inFlight {
            try? await joinFlight(flight.task)
            await acknowledgeManualIfCurrent(id, cycle: manualCycle)
            return
        }

        let now = clock.now()
        let provider: any ProductionUsageProvider
        let spendsNetworkRestore: Bool
        switch admission(for: state, trigger: trigger, now: now) {
        case .start(let admitted, let spends):
            provider = admitted
            spendsNetworkRestore = spends
        case .refuse:
            await acknowledgeManualIfCurrent(id, cycle: manualCycle)
            return
        case .misconfigured:
            state.phase = .configurationFailure
            states[id] = state
            await reporter?.receive(
                report(state, isRefreshing: false, snapshot: .unchanged)
            )
            await acknowledgeManualIfCurrent(id, cycle: manualCycle)
            return
        }

        // Spend the restoration only here, where a request is actually committed. A poll refused by
        // the hard floor or the soft TTL costs nothing and must not consume the account's one shot.
        if spendsNetworkRestore {
            state.networkRestoreBypassSpent = true
        }
        state.lastRequestStartedAt = now

        let flightID = mintFlightID()
        let key = FlightKey(account: id, flight: flightID)
        let activity = activityRunEpoch.map {
            PollingActivityIdentity(
                accountID: id,
                runEpoch: $0,
                flightID: flightID,
                trigger: trigger
            )
        }
        let activityReporter = reporter
        let requestTask = Task(priority: PollingPolicy.priority(for: trigger)) { [weak activityReporter] in
            if let activity {
                await activityReporter?.pollingActivityDidBegin(activity)
            }
            await self.runFlight(key, provider: provider, trigger: trigger)
            if let activity {
                await activityReporter?.pollingActivityDidEnd(activity)
            }
        }
        let timeoutDeadline = clock.adding(PollingPolicy.usageFlightTimeout, to: now)
        let timeoutTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(until: timeoutDeadline, tolerance: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flightTimedOut(key)
        }

        state.inFlight = FlightHandle(
            id: flightID,
            task: requestTask,
            timeoutTask: timeoutTask,
            latestGETStartedAt: nil,
            isSettled: false
        )
        states[id] = state

        // The same escapable join for the flight this supervisor started. Leaving does not
        // abandon the request: `runFlight` owns the settlement, the timeout and the report, and
        // all three happen whether or not anybody is still waiting here.
        try? await joinFlight(requestTask)
        await acknowledgeManualIfCurrent(id, cycle: manualCycle)
    }

    private enum PollAdmission {
        case start(provider: any ProductionUsageProvider, spendsNetworkRestore: Bool)
        case refuse
        case misconfigured
    }

    /// Whether this trigger, at this instant, becomes a request. Every refusal is silent and
    /// costs the account nothing — in particular it never spends the network-restoration credit,
    /// which belongs to a request that actually leaves.
    private func admission(
        for state: AccountState,
        trigger: PollTrigger,
        now: PollInstant
    ) -> PollAdmission {
        let isBackedOff = state.backoffUntil.map { now < $0 } ?? false
        let spendsNetworkRestore = isBackedOff
            && canSpendNetworkRestore(trigger, state: state, now: now)
        if isBackedOff, !spendsNetworkRestore { return .refuse }

        if let lastStart = state.lastRequestStartedAt,
           clock.duration(from: lastStart, to: now) < PollingPolicy.hardFloor
        {
            return .refuse
        }

        if !PollingPolicy.isAttention(trigger),
           let cachedAt = state.cache?.at,
           clock.duration(from: cachedAt, to: now) < PollingPolicy.softTTL(state.config.provider)
        {
            return .refuse
        }

        guard let provider = providers[state.config.provider],
              provider.provider == state.config.provider
        else {
            return .misconfigured
        }
        return .start(provider: provider, spendsNetworkRestore: spendsNetworkRestore)
    }

    func upsert(_ accounts: [AccountConfig], epochs: [AccountID: UInt64]) async {
        for account in accounts {
            guard let epoch = epochs[account.id] else { continue }

            if var existing = states[account.id] {
                existing.config = account
                existing.epoch = epoch
                states[account.id] = existing
                continue
            }

            let phase: AccountPollPhase
            if case .needsReauthentication = account.authorizationState {
                phase = .suspendedForReauthentication
            } else {
                phase = .waitingForFirstSnapshot
            }

            let state = AccountState(config: account, epoch: epoch, phase: phase)
            states[account.id] = state
            await reporter?.receive(
                report(state, isRefreshing: false, snapshot: .unchanged)
            )
        }
    }

    func suspend(_ id: AccountID, epoch: UInt64) async {
        guard var state = states[id] else { return }

        state.epoch = epoch
        retireFlight(in: &state)
        state.phase = .suspendedForReauthentication
        states[id] = state
        await reporter?.receive(
            report(state, isRefreshing: false, snapshot: .unchanged)
        )
    }

    func resetLineage(_ id: AccountID, revision: CredentialRevision, epoch: UInt64) async {
        guard var state = states[id] else { return }

        retireFlight(in: &state)
        let reset = AccountState.recreatedForLineageReset(
            from: state,
            epoch: epoch,
            lineageRevision: revision
        )
        states[id] = reset
        await reporter?.receive(
            report(reset, isRefreshing: false, snapshot: .cleared)
        )
    }

    func remove(_ id: AccountID) async {
        guard var state = states[id] else { return }
        retireFlight(in: &state)
        states[id] = nil
    }

    func stopAll() async {
        isStopping = true
        defer { isStopping = false }

        for id in stableIDs() {
            guard var state = states[id] else { continue }
            retireFlight(in: &state)
            states[id] = state
        }
        for id in stableIDs() {
            guard let state = states[id] else { continue }
            await reporter?.receive(
                report(state, isRefreshing: false, snapshot: .unchanged)
            )
        }
    }

    // MARK: - One flight

    /// The trigger travels the whole flight because the GET at the end of it is built from the
    /// trigger: `ProviderNetworkConstraints` decides from it whether this poll may use a
    /// constrained or expensive network path. A retry after a 401 is the same poll, so it keeps
    /// the same answer.
    private func runFlight(
        _ key: FlightKey,
        provider: any ProductionUsageProvider,
        trigger: PollTrigger
    ) async {
        let outcome = await executeFlight(key, provider: provider, trigger: trigger)
        if let outcome {
            await settleFlight(key, outcome: outcome)
        }
        finishFlight(key)
    }

    private func executeFlight(
        _ key: FlightKey,
        provider: any ProductionUsageProvider,
        trigger: PollTrigger
    ) async -> FlightOutcome? {
        guard let state = currentState(key) else { return nil }
        await reporter?.receive(report(state, isRefreshing: true, snapshot: .unchanged))
        guard isCurrent(key) else { return nil }
        if Task.isCancelled { return .temporaryFailure(attemptedAt: nil) }

        let token: ValidAccessToken
        do {
            token = try await vault.getValidToken(accountID: key.account)
        } catch {
            return vaultOutcome(error, key: key, attemptedAt: nil)
        }
        guard isCurrent(key) else { return nil }
        if Task.isCancelled { return .temporaryFailure(attemptedAt: nil) }
        clearRejectedRevisionIfSuperseded(key, revision: token.revision)

        let outcome = await attemptUsage(key, provider: provider, token: token, trigger: trigger)
        // A 401 on the first attempt is a question, not an answer: the token may simply have been
        // superseded. One refresh and one retry decide it.
        guard case .authorizationRejected(let revision, let attemptedAt) = outcome else {
            return outcome
        }
        return await recoverUnauthorized(
            key,
            provider: provider,
            rejectedRevision: revision,
            attemptedAt: attemptedAt,
            trigger: trigger
        )
    }

    /// One GET with one token: start it, join it, and read the answer into an outcome.
    ///
    /// `.authorizationRejected` here means only "the server refused this token". Whether that is
    /// recoverable is the caller's question, because it depends on whether the token has already
    /// been refreshed once.
    private func attemptUsage(
        _ key: FlightKey,
        provider: any ProductionUsageProvider,
        token: ValidAccessToken,
        trigger: PollTrigger
    ) async -> FlightOutcome? {
        let attemptedAt = clock.wallNow()
        recordGETStart(
            key,
            attemptedAt: attemptedAt
        )

        // The handle is a detached observation, so cancelling this task would not reach it on its
        // own. The cancellation handler is what stops the request on the wire, and it is all that
        // is needed: a cancelled GET that completes anyway returns a number into a flight that
        // is no longer the account's, and nobody reads it.
        let handle = provider.startUsageRequest(
            id: UsageRequestID(rawValue: UUID()),
            token: token,
            trigger: trigger
        )
        let result = await withTaskCancellationHandler {
            await handle.result()
        } onCancel: {
            handle.cancel()
        }

        guard let state = currentState(key) else {
            return nil
        }
        if Task.isCancelled { return .temporaryFailure(attemptedAt: attemptedAt) }

        switch result {
        case .success(let snapshot):
            guard snapshot.provider == state.config.provider,
                  snapshot.provider == provider.provider
            else {
                assertionFailure("usage snapshot provider tag mismatch")
                return .providerTagMismatch(attemptedAt: attemptedAt)
            }
            return .success(snapshot: snapshot, attemptedAt: attemptedAt)
        case .failure(.unauthorized):
            return .authorizationRejected(revision: token.revision, attemptedAt: attemptedAt)
        case .failure(let error):
            return .providerFailure(error: error, attemptedAt: attemptedAt)
        case .cancelled:
            return .temporaryFailure(attemptedAt: attemptedAt)
        }
    }

    private func recoverUnauthorized(
        _ key: FlightKey,
        provider: any ProductionUsageProvider,
        rejectedRevision: CredentialRevision,
        attemptedAt: Date,
        trigger: PollTrigger
    ) async -> FlightOutcome? {
        guard let state = currentState(key) else { return nil }
        // This exact credential has already been refused once and refreshed once. Asking again
        // would spend the user's rate limit proving the same thing.
        if state.authorizationRejectedRevision == rejectedRevision {
            return .authorizationRejected(revision: rejectedRevision, attemptedAt: attemptedAt)
        }

        let refreshed: ValidAccessToken
        do {
            refreshed = try await vault.refreshAfterUnauthorized(
                accountID: key.account,
                rejectedRevision: rejectedRevision
            )
        } catch {
            return vaultOutcome(error, key: key, attemptedAt: attemptedAt)
        }
        guard isCurrent(key) else { return nil }
        if Task.isCancelled { return .temporaryFailure(attemptedAt: attemptedAt) }

        return await attemptUsage(key, provider: provider, token: refreshed, trigger: trigger)
    }

    private func vaultOutcome(_ error: any Error, key: FlightKey, attemptedAt: Date?) -> FlightOutcome? {
        guard isCurrent(key) else { return nil }
        guard let vaultError = error as? TokenVaultError else {
            return .temporaryFailure(attemptedAt: attemptedAt)
        }
        return .vaultFailure(error: vaultError, attemptedAt: attemptedAt)
    }

    /// The single settlement gate. Whoever gets here first — the request or its ceiling — claims
    /// the flight inside one actor turn, before any suspension, so the other returns empty-handed.
    private func settleFlight(_ key: FlightKey, outcome: FlightOutcome) async {
        guard var state = currentState(key),
              var flight = state.inFlight,
              !flight.isSettled
        else { return }

        flight.isSettled = true
        flight.timeoutTask.cancel()
        state.inFlight = flight

        let failuresBefore = state.consecutiveFailures
        let snapshotDisposition: SnapshotDisposition?
        switch outcome {
        case .success(let snapshot, let attemptedAt):
            state.lastAttemptAt = attemptedAt
            state.lastSuccessAt = clock.wallNow()
            state.cache = (snapshot, clock.now())
            state.consecutiveFailures = 0
            state.authorizationRejectedRevision = nil
            state.phase = .current
            snapshotDisposition = .replaced(snapshot)

        case .providerTagMismatch(let attemptedAt):
            state.lastAttemptAt = attemptedAt
            state.phase = .configurationFailure
            snapshotDisposition = .unchanged

        case .providerFailure(let error, let attemptedAt):
            switch error {
            case .unauthorized:
                preconditionFailure("unauthorized must pass through the one recovery path")
            case .rateLimited(let retryAfter):
                state.lastAttemptAt = attemptedAt
                applyRateLimit(retryAfter, to: &state)
                let retryAt = state.backoffUntil.map(clock.wallDate(for:))
                state.phase = .stale(.rateLimited(retryAt: retryAt))
            case .temporarilyUnavailable:
                state.lastAttemptAt = attemptedAt
                state.consecutiveFailures += 1
                state.phase = .stale(.temporarilyUnavailable)
            case .invalidPayload:
                state.lastAttemptAt = attemptedAt
                state.consecutiveFailures += 1
                state.phase = .stale(.invalidPayload)
            case .configuration:
                // Both current providers throw `.configuration` only before `transport.send`.
                // The provider invocation happened, but no GET crossed the request boundary.
                state.phase = .configurationFailure
            }
            snapshotDisposition = .unchanged

        case .vaultFailure(let error, let attemptedAt):
            if let attemptedAt {
                state.lastAttemptAt = attemptedAt
            }
            switch error {
            case .credentialStoreInProgress:
                assertionFailure("credentialStoreInProgress is unreachable from polling")
                state.consecutiveFailures += 1
                state.phase = .stale(.temporarilyUnavailable)
                snapshotDisposition = .unchanged
            case .temporarilyUnavailable:
                state.consecutiveFailures += 1
                state.phase = .stale(.temporarilyUnavailable)
                snapshotDisposition = .unchanged
            case .storageTemporarilyUnavailable:
                state.consecutiveFailures += 1
                state.phase = .stale(.storageTemporarilyUnavailable)
                snapshotDisposition = .unchanged
            case .credentialUnavailable, .providerMismatch:
                state.phase = .configurationFailure
                snapshotDisposition = .unchanged
            case .credentialCorrupt:
                state.consecutiveFailures += 1
                state.phase = .stale(.credentialUnreadable)
                snapshotDisposition = .unchanged
            case .accountRemoved:
                snapshotDisposition = nil
            case .reauthenticationRequired:
                // No epoch of its own. The engine found out first, but what the account *is*
                // is still the store's question: this report puts the account in front of the
                // user, the catalog records that it needs signing in again, and the
                // reconciliation that follows mints the epoch and suspends. The flight this
                // outcome belongs to is already settled, so there is nothing left to invalidate.
                state.phase = .suspendedForReauthentication
                snapshotDisposition = .unchanged
            }

        case .authorizationRejected(let revision, let attemptedAt):
            state.authorizationRejectedRevision = revision
            state.lastAttemptAt = attemptedAt
            state.consecutiveFailures += 1
            state.phase = .stale(.authorizationRejectedAfterRefresh)
            snapshotDisposition = .unchanged

        case .temporaryFailure(let attemptedAt):
            if let attemptedAt {
                state.lastAttemptAt = attemptedAt
            }
            state.consecutiveFailures += 1
            state.phase = .stale(.temporarilyUnavailable)
            snapshotDisposition = .unchanged
        }

        // One place decides the failure backoff, so no failure mode can be added later that widens
        // the streak and forgets to widen the gate.
        if state.consecutiveFailures == 0 {
            state.failureBackoffUntil = nil
            state.networkRestoreBypassSpent = false
        } else if state.consecutiveFailures > failuresBefore {
            applyFailureBackoff(to: &state)
        }
        states[key.account] = state

        if let snapshotDisposition {
            // `inFlight` deliberately remains installed through this awaited report. A later
            // caller joins the settled flight instead of starting a successor that could overtake
            // this report or overlap the owned request.
            await reporter?.receive(
                report(state, isRefreshing: false, snapshot: snapshotDisposition)
            )
        }
    }

    private func flightTimedOut(_ key: FlightKey) async {
        guard !Task.isCancelled,
              let flight = currentFlight(key),
              !flight.isSettled
        else { return }

        // The attempt has had its ceiling. Claim the settlement first — that happens in one
        // actor turn, so a request completing this instant finds the flight already settled —
        // and only then cancel the task, which cancels the GET with it.
        await settleFlight(
            key,
            outcome: .temporaryFailure(attemptedAt: flight.latestGETStartedAt)
        )
        flight.task.cancel()
    }

    /// Clears the flight once its task is on its way out. `inFlight != nil` therefore means
    /// exactly "this account's attempt is still running", which is what every joiner reads.
    private func finishFlight(_ key: FlightKey) {
        guard var state = states[key.account],
              let flight = state.inFlight,
              flight.id == key.flight
        else { return }
        flight.timeoutTask.cancel()
        state.inFlight = nil
        states[key.account] = state
    }

    /// Drops a live attempt on the floor. The task is cancelled, which cancels the GET; a joiner
    /// already holds the task handle and unblocks when it returns.
    private func retireFlight(in state: inout AccountState) {
        guard let flight = state.inFlight else { return }
        state.inFlight = nil
        flight.task.cancel()
        flight.timeoutTask.cancel()
    }

    // MARK: - Backoff

    /// A path transition from unsatisfied to satisfied is new evidence that the cause of the
    /// failure streak is gone, so it earns one attempt through the failure backoff.
    ///
    /// It earns exactly one. If that attempt also fails, the link was not really back, and every
    /// later restoration waits for the backoff like any other trigger. A success clears the streak
    /// and hands the account a fresh restoration credit.
    private func canSpendNetworkRestore(
        _ trigger: PollTrigger,
        state: AccountState,
        now: PollInstant
    ) -> Bool {
        guard trigger == .networkRestored, !state.networkRestoreBypassSpent else { return false }
        guard let rateLimit = state.rateLimitBackoffUntil else { return true }
        return now >= rateLimit
    }

    /// Mirrors `PollingPolicy.failureBackoff` into the engine gate, so every failure — not only a
    /// 429 — is enforced against every trigger. Monotonic: an existing later deadline stands.
    private func applyFailureBackoff(to state: inout AccountState) {
        let now = clock.now()
        let widened = PollingPolicy.failureBackoff(
            consecutiveFailures: state.consecutiveFailures
        )
        guard widened > .zero else { return }
        let floorRemaining = state.lastRequestStartedAt.map {
            max(.zero, PollingPolicy.hardFloor - clock.duration(from: $0, to: now))
        } ?? .zero
        let candidate = clock.adding(max(widened, floorRemaining), to: now)
        state.failureBackoffUntil = state.failureBackoffUntil.map {
            max($0, candidate)
        } ?? candidate
    }

    private func applyRateLimit(
        _ retryAfter: Duration?,
        to state: inout AccountState
    ) {
        let now = clock.now()
        if let last = state.lastHeaderlessRateLimitAt,
           clock.duration(from: last, to: now) >= PollingPolicy.rateLimitCleanReset
        {
            state.rateLimitPenalty = nil
        }

        let base: Duration
        if let retryAfter, retryAfter > .zero {
            // Honor every positive server delay. Only the clock's representable future range can
            // shorten it; the hard floor and an already-later deadline can only extend the wait.
            base = PollingPolicy.representableDelay(retryAfter, from: now)
        } else {
            base = state.rateLimitPenalty ?? PollingPolicy.rateLimitFirstBackoff
            state.rateLimitPenalty = min(
                base * PollingPolicy.rateLimitEscalationNumerator
                    / PollingPolicy.rateLimitEscalationDenominator,
                PollingPolicy.rateLimitCap
            )
            state.lastHeaderlessRateLimitAt = now
        }

        let floorRemaining = state.lastRequestStartedAt.map {
            max(.zero, PollingPolicy.hardFloor - clock.duration(from: $0, to: now))
        } ?? .zero
        let candidate = clock.adding(max(base, floorRemaining), to: now)
        state.rateLimitBackoffUntil = state.rateLimitBackoffUntil.map {
            max($0, candidate)
        } ?? candidate
    }

    // MARK: - State access

    private func recordGETStart(_ key: FlightKey, attemptedAt: Date) {
        guard var state = currentState(key),
              var flight = state.inFlight
        else { return }
        flight.latestGETStartedAt = attemptedAt
        state.inFlight = flight
        states[key.account] = state
    }

    private func clearRejectedRevisionIfSuperseded(_ key: FlightKey, revision: CredentialRevision) {
        guard var state = currentState(key) else { return }
        if let rejected = state.authorizationRejectedRevision, rejected != revision {
            state.authorizationRejectedRevision = nil
            states[key.account] = state
        }
    }

    private func currentState(_ key: FlightKey) -> AccountState? {
        guard let state = states[key.account], state.inFlight?.id == key.flight else {
            return nil
        }
        return state
    }

    private func currentFlight(_ key: FlightKey) -> FlightHandle? {
        currentState(key)?.inFlight
    }

    private func isCurrent(_ key: FlightKey) -> Bool {
        currentState(key) != nil
    }

    private func stableIDs() -> [AccountID] {
        states.keys.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
    }

    private func mintFlightID() -> UInt64 {
        precondition(nextFlightID != .max, "polling flight ID exhausted")
        nextFlightID += 1
        return nextFlightID
    }

    /// Tells the store this account's part of a manual refresh is over, if this supervisor is
    /// still the one entitled to say so.
    ///
    /// `Task.isCancelled` reads the *supervisor's* task, and dropping the acknowledgement when it
    /// is cancelled is deliberate, not an oversight. A retired supervisor does not speak for the
    /// cycle, because retirement does not mean the same thing every time: a supervisor retired as
    /// `.replaced` is succeeded at once by one that inherits the same cycle and will settle it,
    /// and a supervisor that acknowledged on its way out would end the cycle — stopping the
    /// spinner and re-arming Refresh All — while the refresh it announced was still running.
    ///
    /// So what a retirement means is the store's to decide, at the site that performs it, where
    /// the reason is known. Every reason that drops a supervisor without a successor settles the
    /// cycle there: `.removed`, `.suspended`, `.stopped`, `.lineageReset` and `.displayDark`.
    private func acknowledgeManualIfCurrent(_ id: AccountID, cycle: UInt64?) async {
        guard !Task.isCancelled, let cycle else { return }
        await reporter?.manualParticipantSettled(id, cycle: cycle)
    }

    private func report(
        _ state: AccountState,
        isRefreshing: Bool,
        snapshot: SnapshotDisposition
    ) -> PollReport {
        PollReport(
            accountID: state.config.id,
            epoch: state.epoch,
            phase: state.phase,
            isRefreshing: isRefreshing,
            lastAttemptAt: state.lastAttemptAt,
            lastSuccessAt: state.lastSuccessAt,
            snapshot: snapshot,
            lastRequestStartedAt: state.lastRequestStartedAt,
            cachedAt: state.cache?.at,
            backoffUntil: state.backoffUntil,
            consecutiveFailures: state.consecutiveFailures
        )
    }
}
