import Dispatch
import Foundation
import QotaFolioCore
import Synchronization

nonisolated enum VaultCommitError: Error, Sendable {
    case addWouldOverwriteExistingCredential
    case invalidTokenSet
    case envelopeEncodingFailed
}

nonisolated struct RefreshFlight: Sendable {
    let id: UUID
    let task: Task<ValidAccessToken, any Error>
}

nonisolated struct StoreAttempt: Sendable {
    let id: UUID
    let generation: UInt64
}

nonisolated struct RefreshResponseSummary: Sendable {
    let httpStatus: Int
    let bodyByteCount: Int
}

/// Ending every grant this app holds, for the one caller that means all of them.
///
/// "Remove My Data" needs this and nothing else the vault can do, so this is what it is handed.
/// The vault is where it lives because the vault is the only thing that holds a refresh token,
/// and a refresh token has no business leaving it — not even to be revoked.
public nonisolated protocol OwnedGrantEnding: Sendable {
    func endEveryGrant() async -> OwnedGrantRemoval
}

/// What a whole-app removal did on this Mac, and what it left running on the network.
///
/// Two facts, and they are deliberately not one. The local deletion either happened or it did
/// not, and the user is told which. The revokes have no outcome anyone can honestly report —
/// RFC 7009 has the server answer 200 both for a token it revoked and for one it never issued —
/// so there is nothing to branch on, only something a caller may give a bounded moment before
/// the process ends.
///
/// Folding the two together would make a deadline that expired look exactly like a wipe that
/// failed, and telling a user their sign-ins are still on this Mac when they are not — or worse,
/// the reverse — is the one thing this removal must never get wrong.
public nonisolated struct OwnedGrantRemoval: Sendable {
    /// True when every credential this app owns is gone from this Mac.
    public let credentialsDeleted: Bool

    private let revocations: Task<Void, Never>

    init(credentialsDeleted: Bool, revocations: Task<Void, Never>) {
        self.credentialsDeleted = credentialsDeleted
        self.revocations = revocations
    }

    /// Waits for the revokes this removal started. Optional, and the caller owns the deadline.
    ///
    /// There is deliberately no way to cancel them from here. Cancelling is the one thing a
    /// caller could do that would make the app worse at the job the user has just asked for, and
    /// a caller that has waited long enough already has what it needs: it stops waiting, and
    /// leaves them running for as long as the process lives.
    public func awaitRevocations() async { await revocations.value }
}

/// One grant, read out of the store before anything was deleted, with the client that can end it.
private nonisolated struct PendingRevocation: Sendable {
    let revoker: any GrantRevoking
    let refreshToken: SecretString
}

/// What one refresh attempt found, or did.
private nonisolated enum RefreshPreparedResult: Sendable {
    /// Nothing needed rotating — or another flight rotated first, and this is what it wrote.
    case current(StoredTokenEnvelope)
    /// This flight rotated the credential, and this is the envelope it stored.
    case committed(envelope: StoredTokenEnvelope, response: RefreshResponseSummary)
    /// The provider refused the lineage. Reconnecting is the only way back.
    case lineageRejected(
        revision: CredentialRevision,
        provider: AccountProvider,
        response: RefreshResponseSummary
    )
}

/// The credentials, and the one thread that is allowed to wait on `securityd`.
///
/// This actor runs on its own `DispatchSerialQueue` rather than the default actor executor, for
/// the same reason `CatalogCommitWriter` and `UsageHistoryWriter` do — and with more force than
/// either. Every `CredentialItemStore` call below is a synchronous `SecItemCopyMatching`,
/// `SecItemUpdate` or `SecItemDelete`: an XPC round trip to `securityd` that returns when
/// `securityd` decides, and that can wait on a locked keychain, on a user unlocking one, or on a
/// device that has not woken up. A file write blocks for milliseconds and has an upper bound you
/// can reason about. A Keychain call has neither.
///
/// Two costs come from leaving that on the cooperative pool, and the second is the one that hurts:
///
///  1. One pool thread is consumed for the duration, on a pool of roughly one thread per core that
///     is shared with every provider request.
///  2. **A blocked actor is not a suspended actor.** An `await` releases an actor; a blocking
///     syscall does not. While `securityd` is slow, every vault caller queues behind it with no
///     bound — the polling engine's `getValidToken`, the add flow's `performStore`, and the quit's
///     `deleteTokens` and `endEveryGrant`. That is the mechanism that spends a termination budget,
///     and it is why every shutdown wait in this app needs a deadline that does not depend on
///     cancellation.
///
/// The private queue does not make a Keychain call interruptible — nothing can. It confines the
/// blocking to one dedicated thread that exists for exactly this purpose, which is the property
/// the other two I/O actors already have.
///
/// Serial does not mean the vault decides the order of its callers: Swift makes no promise about
/// the order in which concurrent calls to an actor are serviced, whatever executor it runs on.
/// Ordering here comes from `CredentialRevision` and the per-account flight and store latches.
public actor QotaFolioTokenVault: TokenVault, TokenVaultMaintenance, OwnedGrantEnding {
    private let queue = DispatchSerialQueue(
        label: "net.c2coast.QotaFolio.token-vault",
        qos: .userInitiated
    )

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private let itemStore: any CredentialItemStore
    private let refreshDecoders: [AccountProvider: any ProviderRefreshResponseDecoder]
    private let revokers: [AccountProvider: any GrantRevoking]
    private let transport: any HTTPTransport
    private let now: @Sendable () -> Date
    private let sink: (any AccountAuthorizationStateSink)?
    private let log: (any RedactingLog)?

    private var inFlightRefresh: [AccountID: RefreshFlight] = [:]
    private var activeStore: [AccountID: StoreAttempt] = [:]
    private var lifecycleGeneration: [AccountID: UInt64] = [:]

    public init(
        itemStore: any CredentialItemStore,
        refreshDecoders: [AccountProvider: any ProviderRefreshResponseDecoder],
        transport: any HTTPTransport,
        now: @Sendable @escaping () -> Date = { Date() },
        sink: (any AccountAuthorizationStateSink)? = nil,
        log: (any RedactingLog)? = nil,
        revokers: [AccountProvider: any GrantRevoking] = [:]
    ) {
        self.itemStore = itemStore
        self.refreshDecoders = refreshDecoders
        self.transport = transport
        self.now = now
        self.sink = sink
        self.log = log
        self.revokers = revokers
    }

    public func performStore(
        _ request: CredentialStoreRequest,
        using acquirer: any OAuthTokenAcquirer,
        report: @MainActor @Sendable @escaping (AccountFlowPhase) -> Void
    ) async throws -> CredentialStoreReceipt {
        guard activeStore[request.accountID] == nil else {
            throw TokenVaultError.credentialStoreInProgress
        }
        guard acquirer.provider == request.provider else {
            throw TokenVaultError.providerMismatch
        }

        let attempt = StoreAttempt(
            id: UUID(),
            generation: generation(for: request.accountID)
        )
        activeStore[request.accountID] = attempt
        defer { finishStoreAttempt(attempt, accountID: request.accountID) }

        let tokens = try await acquirer.acquireTokens(report: report)
        try Task.checkCancellation()
        await report(.storing)
        try Task.checkCancellation()

        guard activeStore[request.accountID]?.id == attempt.id else {
            assertionFailure("A credential store attempt lost ownership of its slot.")
            throw TokenVaultError.accountRemoved
        }
        guard generation(for: request.accountID) == attempt.generation else {
            throw TokenVaultError.accountRemoved
        }
        guard tokenProvider(tokens) == request.provider else {
            throw TokenVaultError.providerMismatch
        }

        let reference = CredentialReference(accountID: request.accountID)
        let existingData = try readData(reference, accountID: request.accountID)
        switch request.purpose {
        case .add:
            guard existingData == nil else {
                assertionFailure("A fresh add would overwrite an existing credential.")
                throw VaultCommitError.addWouldOverwriteExistingCredential
            }
        case .reauthenticate:
            if let existingData,
               let existingEnvelope = try? StoredTokenCoder.decode(existingData),
               existingEnvelope.provider != request.provider {
                throw TokenVaultError.providerMismatch
            }
        }

        let revision = CredentialRevision(rawValue: UUID())
        let envelope = try makeEnvelope(
            from: tokens,
            provider: request.provider,
            revision: revision,
            receivedAt: now()
        )
        let data: Data
        do {
            data = try StoredTokenCoder.encode(envelope)
        } catch {
            throw VaultCommitError.envelopeEncodingFailed
        }

        try writeData(data, reference: reference, accountID: request.accountID)
        emit(
            operation: .performStore,
            outcome: .ok,
            accountID: request.accountID,
            provider: request.provider,
            code: "vault.store.committed",
            revision: revision
        )
        return CredentialStoreReceipt(
            accountID: request.accountID,
            provider: request.provider,
            revision: revision
        )
    }

    public func getValidToken(accountID: AccountID) async throws -> ValidAccessToken {
        let envelope = try readEnvelope(accountID: accountID)
        if now() < refreshDeadline(for: envelope) {
            return validAccessToken(from: envelope)
        }
        return try await refresh(accountID: accountID, mode: .proactive)
    }

    public func refreshAfterUnauthorized(
        accountID: AccountID,
        rejectedRevision: CredentialRevision
    ) async throws -> ValidAccessToken {
        let envelope = try readEnvelope(accountID: accountID)
        if envelope.revision != rejectedRevision {
            return validAccessToken(from: envelope)
        }
        return try await refresh(
            accountID: accountID,
            mode: .forced(rejectedRevision: rejectedRevision)
        )
    }

    /// Ends one account's grant — on this Mac first, then at the provider.
    ///
    /// The order is deliberate, and it is the reverse of the one Anthropic's own client uses.
    /// Deleting first means no network failure, no cancellation and no quit can leave a
    /// credential on the user's Mac after they asked for it to go, which is the harm this path
    /// exists to prevent. Revoking afterwards, with the secret already in hand, costs nothing and
    /// ends the grant at the provider as well; a revoke that never lands leaves a live token on a
    /// settings page the user can clear themselves.
    ///
    /// The app revokes only a grant it minted. Every credential here came from QotaFolio's own
    /// PKCE flow and lives in QotaFolio's own Keychain item, and the app reads no other
    /// application's credential store.
    ///
    /// `endEveryGrant()` is this for the whole app, and the two must never disagree about what
    /// ending a grant means.
    public func deleteTokens(for accountID: AccountID) async throws {
        lifecycleGeneration[accountID] = generation(for: accountID) &+ 1
        if let flight = inFlightRefresh.removeValue(forKey: accountID) {
            flight.task.cancel()
        }

        // Read before the delete, because after it there is nothing left to revoke with. A
        // credential that is missing or unreadable simply has no grant this app can end.
        let grant = try? readEnvelope(accountID: accountID)

        var deletionFailure: TokenVaultError?
        do {
            try itemStore.delete(CredentialReference(accountID: accountID))
            emit(
                operation: .keychainWrite,
                outcome: .ok,
                accountID: accountID,
                provider: nil,
                code: "keychain.delete.ok"
            )
        } catch {
            deletionFailure = storageError(
                error,
                operation: .keychainWrite,
                accountID: accountID,
                code: "keychain.delete.failed"
            )
        }

        if let grant, let revoker = revokers[grant.provider] {
            await revoker.revoke(refreshToken: refreshToken(from: grant))
        }

        if let deletionFailure { throw deletionFailure }
    }

    /// Ends every grant this app holds — on this Mac first, then at each provider that issued one.
    ///
    /// This is `deleteTokens(for:)` for the whole app, and it is what "Remove My Data" is wired
    /// to: the button that means "I am done with this app entirely" ends every grant, exactly as
    /// Disconnect ends one.
    ///
    /// **Read, then delete, then talk to the network — in that order and no other.** After the
    /// Keychain items are gone there is no refresh token left to revoke with, so the envelopes
    /// are read first. And the deletion never waits for a byte of network: this call returns as
    /// soon as the local half is finished, with the revokes it started still running behind the
    /// handle it hands back. That is the same order Disconnect follows and it matters more here,
    /// because a user who has asked to be gone will not look again.
    ///
    /// **The deletion does not depend on the reading.** Any of those reads can fail — a locked
    /// keychain, an envelope from a schema this build does not know, an item written by a
    /// version that no longer exists — and none of it can leave a credential behind, because the
    /// wipe is a single whole-service delete that names no item at all. A credential this app
    /// cannot read is still deleted. It simply cannot be revoked, and that is the honest trade:
    /// nothing this app can only half-understand becomes a reason to leave it on the user's Mac.
    ///
    /// **Only grants this app minted.** Every credential here came from QotaFolio's own PKCE
    /// flow and lives in QotaFolio's own Keychain service, derived from this bundle's own
    /// identifier — so a Debug build cannot reach the installed app's items, and neither build
    /// can reach another application's. The app reads no other credential store, so there is
    /// nothing else within reach. The rule is "never revoke a credential we did not mint", not
    /// "never revoke".
    ///
    /// A provider that publishes no revocation endpoint — ChatGPT — simply has no entry in
    /// `revokers`. Its credential is deleted and that is all. The dictionary says so, and no
    /// branch anywhere has to ask which provider this is.
    public func endEveryGrant() async -> OwnedGrantRemoval {
        // Nothing may commit a credential on top of the wipe. A refresh whose POST is still in
        // the air re-reads the item before it writes and finds it gone, so a resurrection is
        // already impossible -- this closes it one step earlier and stops a request nobody will
        // ever read. A store attempt is invalidated the same way `deleteTokens(for:)` does it.
        for (accountID, flight) in inFlightRefresh {
            lifecycleGeneration[accountID] = generation(for: accountID) &+ 1
            flight.task.cancel()
        }
        inFlightRefresh.removeAll()
        for accountID in activeStore.keys {
            lifecycleGeneration[accountID] = generation(for: accountID) &+ 1
        }

        let pending = readEveryRevocableGrant()

        var credentialsDeleted = true
        do {
            try itemStore.deleteAllOwnedItems()
            emit(
                operation: .keychainWrite,
                outcome: .ok,
                accountID: nil,
                provider: nil,
                code: "keychain.delete.all.ok"
            )
        } catch {
            credentialsDeleted = false
            _ = storageError(
                error,
                operation: .keychainWrite,
                accountID: nil,
                code: "keychain.delete.all.failed"
            )
        }

        // The revokes run even when the delete refused, and that is deliberate. The user asked to
        // be done with this app. A credential still sitting on their Mac is better dead than
        // alive, and they are told separately that the deletion did not finish.
        //
        // `@concurrent` and not the vault's own executor: these calls need no vault state, and a
        // revoke that stalls must not hold the actor while the rest of the removal runs.
        let revocations = Task { @concurrent in
            await withTaskGroup(of: Void.self) { group in
                for grant in pending {
                    group.addTask { await grant.revoker.revoke(refreshToken: grant.refreshToken) }
                }
            }
        }

        return OwnedGrantRemoval(
            credentialsDeleted: credentialsDeleted,
            revocations: revocations
        )
    }

    /// Every grant this app holds that some provider can be told about, read before anything goes.
    ///
    /// Best effort, item by item, and unable to fail as a whole on purpose. An enumeration that
    /// refuses yields nothing to revoke and changes nothing about the wipe that follows it. A
    /// single item that will not read or decode costs its own revoke and no other.
    ///
    /// One `SecItemCopyMatching` cannot do this: asking for the data of every item at once is
    /// `errSecParam` on this app's keychain. See `KeychainTokenStore.enumerateReferences()`.
    private func readEveryRevocableGrant() -> [PendingRevocation] {
        guard !revokers.isEmpty else { return [] }

        let references: Set<CredentialReference>
        do {
            references = try itemStore.enumerateReferences()
        } catch {
            emit(
                operation: .reconcile,
                outcome: .transient,
                accountID: nil,
                provider: nil,
                code: "keychain.scan.unavailable"
            )
            return []
        }

        var pending: [PendingRevocation] = []
        pending.reserveCapacity(references.count)
        for reference in references {
            guard let data = try? itemStore.read(reference),
                  let envelope = try? StoredTokenCoder.decode(data) else {
                // The credential still goes; only its grant survives, and nothing else in this
                // removal changes. Recorded because every other read in this vault is recorded,
                // and because a user whose grant stayed live deserves the reason to exist
                // somewhere -- an entirely silent path would make it unfindable.
                emit(
                    operation: .keychainRead,
                    outcome: .permanent,
                    accountID: nil,
                    provider: nil,
                    code: "revoke.credential.unreadable"
                )
                continue
            }
            // A provider with no revoker is not a failure and not a branch. ChatGPT publishes no
            // public revocation endpoint, so it has no entry, and the dictionary says so.
            guard let revoker = revokers[envelope.provider] else { continue }
            pending.append(
                PendingRevocation(
                    revoker: revoker,
                    refreshToken: refreshToken(from: envelope)
                )
            )
        }
        return pending
    }

    public func scanStoredCredentials() async -> StoredCredentialScan {
        do {
            let references = try itemStore.enumerateReferences()
            emit(
                operation: .reconcile,
                outcome: .ok,
                accountID: nil,
                provider: nil,
                code: "keychain.scan.ok"
            )
            return .enumerated(references)
        } catch {
            emit(
                operation: .reconcile,
                outcome: .transient,
                accountID: nil,
                provider: nil,
                code: "keychain.scan.unavailable"
            )
            return .unavailable
        }
    }

    /// One reconciliation pass, and the one thing it must never do: report an abort as a clean pass.
    ///
    /// The return type is `CredentialReconcileOutcome` and not a map because an empty map says both
    /// "I finished and there was nothing to repair" and "I stopped because the store would not
    /// answer" — the collapse `StoredCredentialScan` is an enum to forbid, one level up. Each of the
    /// three exits below names the refusal it saw, so no pass can claim to have stopped without
    /// saying what stopped it, and no caller can read a stopped pass as a finished one.
    ///
    /// FAIL-CLOSED: both READ refusals return before a single action is computed, so no
    /// deletion and no `.markNeedsReauthentication` can ever rest on a partial read.
    public func reconcile(
        _ records: [CredentialReconcileRecord]
    ) async -> CredentialReconcileOutcome {
        let stored: Set<CredentialReference>
        do {
            stored = try itemStore.enumerateReferences()
        } catch {
            emit(
                operation: .reconcile,
                outcome: .transient,
                accountID: nil,
                provider: nil,
                code: "reconcile.enumeration.failed"
            )
            return .aborted(.enumerationRefused, reauthenticated: [:])
        }

        var probes = [AccountID: CredentialProbe]()
        probes.reserveCapacity(records.count)
        for record in records {
            do {
                guard let data = try itemStore.read(record.reference) else {
                    probes[record.accountID] = .absent
                    continue
                }
                do {
                    let envelope = try StoredTokenCoder.decode(data)
                    probes[record.accountID] = .present(
                        revision: envelope.revision,
                        provider: envelope.provider
                    )
                } catch {
                    probes[record.accountID] = .unreadable
                }
            } catch {
                emit(
                    operation: .reconcile,
                    outcome: .transient,
                    accountID: record.accountID,
                    provider: record.provider,
                    code: "reconcile.probe.failed"
                )
                return .aborted(.itemReadRefused, reauthenticated: [:])
            }
        }

        let actions = CredentialReconciler.decide(
            records: records,
            stored: stored,
            probes: probes
        )

        var repaired = [AccountID: CredentialRevision]()
        for action in actions {
            switch action {
            case .deleteOrphan(let reference):
                do {
                    // Local only, and deliberately: an orphan has no account row left to name,
                    // this runs at launch, and a launch does not owe the network a request.
                    try itemStore.delete(reference)
                } catch {
                    emit(
                        operation: .reconcile,
                        outcome: .transient,
                        accountID: nil,
                        provider: nil,
                        code: "reconcile.delete.failed"
                    )
                    // The reads all answered and the sweep did not finish. `repaired` is carried out
                    // rather than dropped: an abort rolls nothing back, and every revision in it is
                    // already durably committed to the catalog.
                    return .aborted(.itemDeleteRefused, reauthenticated: repaired)
                }
            case .markConnected(let id, let revision):
                if let sink {
                    // Awaiting the report means awaiting its durable commit, so a revision
                    // only enters `repaired` once the catalog change for it is on the device.
                    await sink.recordConnected(id, revision: revision)
                    repaired[id] = revision
                }
            case .markNeedsReauthentication(let id, let failedRevision):
                if let sink {
                    await sink.recordNeedsReauthentication(
                        id,
                        failedRevision: failedRevision
                    )
                }
            }
        }

        emit(
            operation: .reconcile,
            outcome: .ok,
            accountID: nil,
            provider: nil,
            code: "reconcile.completed"
        )
        return .completed(reauthenticated: repaired)
    }

    private func refresh(
        accountID: AccountID,
        mode: RefreshMode
    ) async throws -> ValidAccessToken {
        if let existing = inFlightRefresh[accountID] {
            return try await joinFlight(existing.task)
        }

        let flightID = UUID()
        let startGeneration = generation(for: accountID)
        let task = Task {
            try await self.executeRefresh(
                accountID: accountID,
                mode: mode,
                flightID: flightID,
                startGeneration: startGeneration
            )
        }
        inFlightRefresh[accountID] = RefreshFlight(id: flightID, task: task)
        // `joinFlight` and not `try await task.value`: a cancelled caller leaves at once instead
        // of staying suspended for as long as the flight takes — bounded, if the join is bare,
        // only by the 60-second request timeout, which is thirty times the termination drain
        // deadline.
        return try await joinFlight(task)
    }

    private func executeRefresh(
        accountID: AccountID,
        mode: RefreshMode,
        flightID: UUID,
        startGeneration: UInt64
    ) async throws -> ValidAccessToken {
        defer { finishRefresh(flightID: flightID, accountID: accountID) }

        let prepared = try await prepareRefresh(
            accountID: accountID,
            mode: mode,
            startGeneration: startGeneration
        )

        switch prepared {
        case .current(let envelope):
            return validAccessToken(from: envelope)

        case .committed(let envelope, let response):
            if let sink {
                // This await spans the catalog's durable commit as well as the MainActor
                // hop, so the rotation this flight performed is on the device before the token
                // that rotation produced is handed to anyone.
                await sink.recordConnected(accountID, revision: envelope.revision)
            }
            try accountSurvivedTheReport(accountID, generation: startGeneration)
            emit(
                operation: .refresh,
                outcome: .ok,
                accountID: accountID,
                provider: envelope.provider,
                code: "refresh.rotated",
                revision: envelope.revision,
                httpStatus: response.httpStatus,
                bodyByteCount: response.bodyByteCount
            )
            return validAccessToken(from: envelope)

        case .lineageRejected(let revision, let provider, let response):
            if let sink {
                await sink.recordNeedsReauthentication(
                    accountID,
                    failedRevision: revision
                )
            }
            try accountSurvivedTheReport(accountID, generation: startGeneration)
            emit(
                operation: .refresh,
                outcome: .permanent,
                accountID: accountID,
                provider: provider,
                code: "refresh.lineage.rejected",
                revision: revision,
                httpStatus: response.httpStatus,
                bodyByteCount: response.bodyByteCount
            )
            throw TokenVaultError.reauthenticationRequired(failedRevision: revision)
        }
    }

    /// The last check before a refresh result crosses the vault's API.
    ///
    /// Reporting to the sink spans a MainActor hop and a durable catalog commit, and the vault is
    /// an actor: a `deleteTokens` for this account can run inside that window. Handing a token
    /// back for an account the user has just removed is the outcome worth a check here, and the
    /// lifecycle generation is what records a removal. The sink hop is nonthrowing, so
    /// cancellation has to be observed explicitly too.
    ///
    /// The generation is the whole check. A credential that changed under this flight is not a
    /// reason to withhold a token that was valid when it was written: the caller's next 401 asks
    /// for the current credential and gets it.
    private func accountSurvivedTheReport(
        _ accountID: AccountID,
        generation startGeneration: UInt64
    ) throws {
        try Task.checkCancellation()
        guard generation(for: accountID) == startGeneration else {
            throw TokenVaultError.accountRemoved
        }
    }

    /// Reads the credential, decides whether it needs rotating, and rotates it if it does.
    ///
    /// Every refresh secret and every raw response byte lives and dies inside this call. What it
    /// returns is an envelope this vault already stored, so nothing addressed to the provider
    /// outlives the request that carried it.
    private func prepareRefresh(
        accountID: AccountID,
        mode: RefreshMode,
        startGeneration: UInt64
    ) async throws -> RefreshPreparedResult {
        try Task.checkCancellation()
        guard generation(for: accountID) == startGeneration else {
            throw TokenVaultError.accountRemoved
        }

        let source = try readEnvelope(accountID: accountID)
        switch mode {
        case .proactive:
            if now() < refreshDeadline(for: source) {
                return .current(source)
            }
        case .forced(let rejectedRevision):
            if source.revision != rejectedRevision {
                return .current(source)
            }
        }

        let sourceRevision = source.revision
        let route: OAuthRefreshRoute = switch source.provider {
        case .anthropic: .anthropic
        case .openai: .openAI
        }
        let request = RefreshEgress.materialize(
            route,
            injecting: refreshToken(from: source)
        )

        let body: Data
        let response: HTTPURLResponse
        do {
            (body, response) = try await transport.send(
                request,
                maxResponseBytes: CREDENTIAL_POST_MAX_BYTES
            )
            try Task.checkCancellation()
        } catch {
            try Task.checkCancellation()
            emit(
                operation: .refresh,
                outcome: .transient,
                accountID: accountID,
                provider: source.provider,
                code: "refresh.transport.failed",
                revision: sourceRevision
            )
            throw TokenVaultError.temporarilyUnavailable
        }
        let responseReceivedAt = now()
        let responseSummary = RefreshResponseSummary(
            httpStatus: response.statusCode,
            bodyByteCount: body.count
        )

        guard generation(for: accountID) == startGeneration else {
            throw TokenVaultError.accountRemoved
        }
        let current: StoredTokenEnvelope
        do {
            current = try readEnvelope(accountID: accountID)
        } catch TokenVaultError.credentialUnavailable {
            throw TokenVaultError.accountRemoved
        }
        // Another flight rotated underneath this one while the POST was in the air. Its result is
        // the live credential and this one's is already stale, so this flight abandons what it was
        // about to write rather than overwriting a newer rotation with an older one.
        guard current.revision == sourceRevision else {
            return .current(current)
        }
        guard current.provider == source.provider else {
            throw TokenVaultError.providerMismatch
        }

        guard let decoder = refreshDecoders[source.provider],
              decoder.provider == source.provider else {
            throw TokenVaultError.providerMismatch
        }

        let delta: OAuthTokenRefreshDelta
        do {
            delta = try decoder.decodeRefreshResponse(
                status: response.statusCode,
                body: body
            )
        } catch let refreshError as TokenRefreshError {
            switch refreshError {
            case .transient:
                emit(
                    operation: .refresh,
                    outcome: .transient,
                    accountID: accountID,
                    provider: source.provider,
                    code: "refresh.decoder.transient",
                    revision: sourceRevision,
                    httpStatus: response.statusCode,
                    bodyByteCount: body.count
                )
                throw TokenVaultError.temporarilyUnavailable
            case .permanent(let failure):
                guard failure.provider == source.provider else {
                    throw TokenVaultError.providerMismatch
                }
                return .lineageRejected(
                    revision: current.revision,
                    provider: current.provider,
                    response: responseSummary
                )
            }
        } catch {
            emit(
                operation: .refresh,
                outcome: .transient,
                accountID: accountID,
                provider: source.provider,
                code: "refresh.decoder.invalid",
                revision: sourceRevision,
                httpStatus: response.statusCode,
                bodyByteCount: body.count
            )
            throw TokenVaultError.temporarilyUnavailable
        }

        let rotated: StoredTokenEnvelope
        do {
            rotated = try mergedEnvelope(
                source: current,
                delta: delta,
                receivedAt: responseReceivedAt
            )
        } catch TokenVaultError.providerMismatch {
            throw TokenVaultError.providerMismatch
        } catch {
            throw TokenVaultError.temporarilyUnavailable
        }

        let data: Data
        do {
            data = try StoredTokenCoder.encode(rotated)
        } catch {
            throw TokenVaultError.temporarilyUnavailable
        }
        try writeData(
            data,
            reference: CredentialReference(accountID: accountID),
            accountID: accountID
        )

        return .committed(envelope: rotated, response: responseSummary)
    }

    private func readEnvelope(accountID: AccountID) throws -> StoredTokenEnvelope {
        let reference = CredentialReference(accountID: accountID)
        guard let data = try readData(reference, accountID: accountID) else {
            throw TokenVaultError.credentialUnavailable
        }
        do {
            return try StoredTokenCoder.decode(data)
        } catch {
            emit(
                operation: .keychainRead,
                outcome: .permanent,
                accountID: accountID,
                provider: nil,
                code: "credential.envelope.corrupt"
            )
            throw TokenVaultError.credentialCorrupt
        }
    }

    private func readData(
        _ reference: CredentialReference,
        accountID: AccountID
    ) throws -> Data? {
        do {
            let data = try itemStore.read(reference)
            emit(
                operation: .keychainRead,
                outcome: .ok,
                accountID: accountID,
                provider: nil,
                code: data == nil ? "keychain.read.absent" : "keychain.read.ok"
            )
            return data
        } catch {
            throw storageError(
                error,
                operation: .keychainRead,
                accountID: accountID,
                code: "keychain.read.failed"
            )
        }
    }

    private func writeData(
        _ data: Data,
        reference: CredentialReference,
        accountID: AccountID
    ) throws {
        do {
            try itemStore.upsert(data, for: reference)
            emit(
                operation: .keychainWrite,
                outcome: .ok,
                accountID: accountID,
                provider: nil,
                code: "keychain.write.ok"
            )
        } catch {
            throw storageError(
                error,
                operation: .keychainWrite,
                accountID: accountID,
                code: "keychain.write.failed"
            )
        }
    }

    private func storageError(
        _ error: any Error,
        operation: DiagOperation,
        accountID: AccountID?,
        code: StaticString
    ) -> TokenVaultError {
        let diagnosticCode: StaticString
        if let keychainError = error as? KeychainError {
            switch keychainError {
            case .unavailable:
                diagnosticCode = "keychain.unavailable"
            case .unexpected:
                diagnosticCode = "keychain.unexpected"
            case .malformedResult:
                diagnosticCode = "keychain.malformed-result"
            }
        } else {
            diagnosticCode = code
        }
        emit(
            operation: operation,
            outcome: .transient,
            accountID: accountID,
            provider: nil,
            code: diagnosticCode
        )
        return .storageTemporarilyUnavailable
    }

    private func makeEnvelope(
        from tokens: OAuthTokenSet,
        provider: AccountProvider,
        revision: CredentialRevision,
        receivedAt: Date
    ) throws -> StoredTokenEnvelope {
        guard receivedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw VaultCommitError.invalidTokenSet
        }

        switch tokens {
        case .anthropic(let accessToken, let refreshToken, let expiresAt):
            guard provider == .anthropic else {
                throw TokenVaultError.providerMismatch
            }
            guard expiresAt.timeIntervalSinceReferenceDate.isFinite else {
                throw VaultCommitError.invalidTokenSet
            }
            guard !accessToken.isEmpty, !refreshToken.isEmpty else {
                throw VaultCommitError.invalidTokenSet
            }
            return StoredTokenEnvelope(
                revision: revision,
                receivedAt: receivedAt,
                provider: provider,
                payload: .anthropic(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiresAt: expiresAt
                )
            )
        case .openai(
            let accessToken,
            let refreshToken,
            let chatGPTAccountID,
            let accessExpiresAt
        ):
            guard provider == .openai else {
                throw TokenVaultError.providerMismatch
            }
            guard accessExpiresAt?.timeIntervalSinceReferenceDate.isFinite != false else {
                throw VaultCommitError.invalidTokenSet
            }
            guard !accessToken.isEmpty,
                  !refreshToken.isEmpty,
                  !chatGPTAccountID.isEmpty else {
                throw VaultCommitError.invalidTokenSet
            }
            return StoredTokenEnvelope(
                revision: revision,
                receivedAt: receivedAt,
                provider: provider,
                payload: .openai(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    chatGPTAccountID: chatGPTAccountID,
                    accessExpiresAt: accessExpiresAt
                )
            )
        }
    }

    /// Builds the envelope a refresh response produces, keeping what the response left out.
    ///
    /// OpenAI's refresh answer may omit `refresh_token` or the account id, and both mean "keep
    /// what you have" rather than "you no longer have one". Blanking either turns a routine
    /// rotation into a sign-in the user has to redo.
    private func mergedEnvelope(
        source: StoredTokenEnvelope,
        delta: OAuthTokenRefreshDelta,
        receivedAt: Date
    ) throws -> StoredTokenEnvelope {
        let revision = CredentialRevision(rawValue: UUID())
        guard receivedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw TokenRefreshError.transient
        }

        switch (source.payload, delta) {
        case (
            .anthropic,
            .anthropic(let accessToken, let refreshToken, let expiresIn)
        ):
            guard source.provider == .anthropic,
                  expiresIn.isFinite,
                  expiresIn > 0 else {
                throw TokenRefreshError.transient
            }
            guard !accessToken.isEmpty, !refreshToken.isEmpty else {
                throw TokenRefreshError.transient
            }
            return StoredTokenEnvelope(
                revision: revision,
                receivedAt: receivedAt,
                provider: .anthropic,
                payload: .anthropic(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    expiresAt: receivedAt.addingTimeInterval(expiresIn)
                )
            )
        case (
            .openai(
                _,
                let oldRefreshToken,
                let oldAccountID,
                _
            ),
            .openai(
                let accessToken,
                let refreshToken,
                let accountID,
                let accessExpiresAt
            )
        ):
            guard source.provider == .openai,
                  accessExpiresAt?.timeIntervalSinceReferenceDate.isFinite != false else {
                throw TokenRefreshError.transient
            }
            guard !accessToken.isEmpty else {
                throw TokenRefreshError.transient
            }
            let mergedRefresh = try refreshToken.map { secret -> SecretString in
                guard !secret.isEmpty else { throw TokenRefreshError.transient }
                return secret
            } ?? oldRefreshToken
            let mergedAccountID = try accountID.map { secret -> SecretString in
                guard !secret.isEmpty else { throw TokenRefreshError.transient }
                return secret
            } ?? oldAccountID
            return StoredTokenEnvelope(
                revision: revision,
                receivedAt: receivedAt,
                provider: .openai,
                payload: .openai(
                    accessToken: accessToken,
                    refreshToken: mergedRefresh,
                    chatGPTAccountID: mergedAccountID,
                    accessExpiresAt: accessExpiresAt
                )
            )
        case (.anthropic, .openai), (.openai, .anthropic):
            throw TokenVaultError.providerMismatch
        }
    }

    private func refreshDeadline(for envelope: StoredTokenEnvelope) -> Date {
        // Five minutes, which is the slack the Codex CLI itself uses. Rotating on the same
        // schedule as the provider's own client is what keeps two holders of one account
        // from racing each other into `refresh_token_reused`.
        let leeway: TimeInterval = 300
        switch envelope.payload {
        case .anthropic(_, _, let expiresAt):
            return expiresAt.addingTimeInterval(-leeway)
        case .openai(_, _, _, let accessExpiresAt):
            // Eight days. An OpenAI refresh token ages out on its own, so a credential nobody
            // has needed for a week still has to rotate before it expires — independently of
            // when the access token happens to run out.
            let rotationDeadline = envelope.receivedAt.addingTimeInterval(8 * 24 * 60 * 60)
            guard let accessExpiresAt else { return rotationDeadline }
            return min(accessExpiresAt.addingTimeInterval(-leeway), rotationDeadline)
        }
    }

    private func validAccessToken(
        from envelope: StoredTokenEnvelope
    ) -> ValidAccessToken {
        switch envelope.payload {
        case .anthropic(let accessToken, _, _):
            return .anthropic(
                accessToken: accessToken,
                revision: envelope.revision
            )
        case .openai(let accessToken, _, let accountID, _):
            return .openai(
                accessToken: accessToken,
                chatGPTAccountID: accountID,
                revision: envelope.revision
            )
        }
    }

    private func refreshToken(from envelope: StoredTokenEnvelope) -> SecretString {
        switch envelope.payload {
        case .anthropic(_, let refreshToken, _),
             .openai(_, let refreshToken, _, _):
            refreshToken
        }
    }

    private func tokenProvider(_ tokens: OAuthTokenSet) -> AccountProvider {
        switch tokens {
        case .anthropic: .anthropic
        case .openai: .openai
        }
    }

    private func generation(for accountID: AccountID) -> UInt64 {
        lifecycleGeneration[accountID, default: 0]
    }

    private func finishStoreAttempt(_ attempt: StoreAttempt, accountID: AccountID) {
        guard let current = activeStore[accountID] else {
            assertionFailure("A credential store attempt slot disappeared before scope exit.")
            return
        }
        guard current.id == attempt.id else {
            assertionFailure("A credential store attempt tried to clear a newer slot.")
            return
        }
        activeStore.removeValue(forKey: accountID)
    }

    private func finishRefresh(flightID: UUID, accountID: AccountID) {
        guard let current = inFlightRefresh[accountID] else { return }
        guard current.id == flightID else {
            assertionFailure("A refresh flight tried to clear a newer slot.")
            return
        }
        inFlightRefresh.removeValue(forKey: accountID)
    }

    private func emit(
        operation: DiagOperation,
        outcome: DiagOutcome,
        accountID: AccountID?,
        provider: AccountProvider?,
        code: StaticString,
        revision: CredentialRevision? = nil,
        httpStatus: Int? = nil,
        bodyByteCount: Int? = nil
    ) {
        log?.emit(
            DiagEvent(
                provider: provider,
                operation: operation,
                outcome: outcome,
                httpStatus: httpStatus,
                sizeBucket: bodyByteCount.map(diagnosticSizeBucket),
                machineErrorCode: code,
                revision: revision,
                accountHash: accountID.map(redactedAccountHash)
            )
        )
    }

    private enum RefreshMode: Sendable {
        case proactive
        case forced(rejectedRevision: CredentialRevision)
    }
}

private nonisolated extension RefreshLineageFailure {
    var provider: AccountProvider {
        switch self {
        case .anthropicInvalidGrant:
            .anthropic
        case .openAIInvalidGrant,
             .openAIRefreshTokenExpired,
             .openAIRefreshTokenInvalidated,
             .openAIRefreshTokenReused:
            .openai
        }
    }
}
