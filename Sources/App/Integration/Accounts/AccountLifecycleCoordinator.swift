import Foundation
import Observation
import QotaFolioCore
import QotaFolioKit
import Synchronization

nonisolated enum TerminationWaitResult<Value: Sendable>: Sendable {
    case completed(Value)
    case expired
}

/// Resolves once. The first of the two racers wins and every later resolution is dropped,
/// so a wait can never be lost between the racer starting and the caller suspending.
nonisolated final class TerminationWaitLatch<Value: Sendable>: Sendable {
    private struct State {
        var result: TerminationWaitResult<Value>?
        var continuation: CheckedContinuation<TerminationWaitResult<Value>, Never>?
    }

    private let state = Mutex(State())

    func wait() async -> TerminationWaitResult<Value> {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { state -> TerminationWaitResult<Value>? in
                if let result = state.result {
                    return result
                }
                state.continuation = continuation
                return nil
            }
            if let immediate {
                continuation.resume(returning: immediate)
            }
        }
    }

    func resolve(_ result: TerminationWaitResult<Value>) {
        let continuation = state.withLock { state -> CheckedContinuation<TerminationWaitResult<Value>, Never>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: result)
    }
}

/// Waits at most `timeout` for `work`, and returns nil when the deadline wins.
///
/// The work keeps running after the deadline; only the caller stops waiting. A structured
/// timeout cannot do that: a task group does not leave its scope until every child returns,
/// so one cancellation-resistant Keychain or browser task would hold the group — and, above
/// it, AppKit's `terminateLater` — open forever. Cancellation is a request, never a
/// guarantee, so every shutdown wait needs a deadline that does not depend on it.
nonisolated func awaitWithinTerminationDeadline<Value: Sendable>(
    _ timeout: Duration,
    _ work: @escaping @Sendable () async -> Value
) async -> Value? {
    let latch = TerminationWaitLatch<Value>()
    Task { @concurrent in
        latch.resolve(.completed(await work()))
    }
    let deadline = Task { @concurrent in
        try? await ContinuousClock().sleep(for: timeout)
        latch.resolve(.expired)
    }
    defer { deadline.cancel() }

    switch await latch.wait() {
    case .completed(let value):
        return value
    case .expired:
        return nil
    }
}

@MainActor @Observable
final class AccountLifecycleCoordinator: AddFlowPresenting {
    /// How long an add waits for the provider to say whose account a grant is.
    ///
    /// The answer is a courtesy — an account whose identity nobody knows works normally — so a
    /// request that stops answering must not be able to hold a sign-in open behind it. Ten
    /// seconds is far past a healthy round trip on a connection that has just completed an OAuth
    /// exchange, and far short of the transport's own minute.
    private static let providerIdentityDeadline: Duration = .seconds(10)

    private struct FlowContext {
        let purpose: CredentialStorePurpose
        var provider: AccountProvider?
        var accountID: AccountID?
        var name: String?
        var reservationHeld: Bool
    }

    /// One attempt's phase channel.
    ///
    /// `report` applies the phase inline, on the main actor, before it returns. The vault and the
    /// acquirers are already `async` and call it as `await report(...)`, so the state that
    /// describes a phase is in place before the code that reported it takes its next step. That is
    /// what `@MainActor` on the closure type buys, and it is why phases are not queued: a queue
    /// puts one hop between the report and the state, with no ordering guarantee across hops, so a
    /// phase can be observed late or out of order relative to the thing it describes.
    private struct Channel {
        let id: UInt64
        let report: @MainActor @Sendable (AccountFlowPhase) -> Void
    }

    // The phase as the provider produced it. `.rateLimited` carries the provider's own absolute deadline, so the
    // phase is handed to the view unchanged — there is nothing to re-anchor and nothing that can drift.
    private(set) var activeFlow: AccountFlowPhase?
    private(set) var activeFlowProvider: AccountProvider?
    private(set) var pendingConnectedAnnouncement: AccountID?

    /// Why the naming step is back on screen after a Continue that could not start a flow.
    ///
    /// Without it the user's own half-filled form reappears, with the provider they picked
    /// unpicked, and nothing said. Set only where a start is refused and the flow survives; every
    /// other path either starts or ends, and both of those are visible.
    private(set) var addFlowRefusal: AddFlowRefusal?

    @ObservationIgnored private let catalog: any AccountCataloging
    @ObservationIgnored private let store: any AccountsStoring
    @ObservationIgnored private let vault: any TokenVault
    @ObservationIgnored private let providerSuites: [AccountProvider: ProviderSuite]
    @ObservationIgnored private let browser: any BrowserOpening
    @ObservationIgnored private let monotonic: any MonotonicClock
    @ObservationIgnored private let log: any RedactingLog
    /// Where "whose account is this grant?" is answered, per provider. Deliberately a factory and
    /// not part of `ProviderSuite`: the suite is built in four places across three targets, and an
    /// identity fetcher is needed at exactly one moment in one flow.
    @ObservationIgnored private let makeIdentitySource: @Sendable (AccountProvider) -> any ProviderIdentityFetching
    @ObservationIgnored private let phaseDidProject: @MainActor @Sendable (AccountFlowPhase) -> Void

    @ObservationIgnored private var context: FlowContext?
    @ObservationIgnored private var flowTask: Task<Void, Never>?
    @ObservationIgnored private var flowTaskAttempt: UInt64?
    /// The attempt whose channel may still deliver a phase.
    ///
    /// Set when the channel opens and cleared when it closes, so a report that arrives from a
    /// straggling acquirer task after finalisation has begun is dropped rather than applied on top
    /// of the state finalisation just wrote.
    @ObservationIgnored private var openPhaseChannel: UInt64?
    @ObservationIgnored private var attempt: UInt64 = 0
    @ObservationIgnored private var browserOpenTask: Task<Void, Never>?
    @ObservationIgnored private var browserOpenTaskIdentifier: UUID?
    @ObservationIgnored private var removalTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingCredentialDeletionIDs: Set<AccountID> = []
    @ObservationIgnored private var identityBackfillTask: Task<Void, Never>?
    /// Set once, by the quit, and never cleared: the process is on its way out.
    ///
    /// Nothing else closes account changes. An uninstall stops polling and deletes, and the app
    /// quits behind it.
    @ObservationIgnored private var accountChangesAreClosedForQuit = false

    init(
        catalog: any AccountCataloging,
        store: any AccountsStoring,
        vault: any TokenVault,
        providerSuites: [AccountProvider: ProviderSuite],
        browser: any BrowserOpening,
        monotonic: any MonotonicClock,
        log: any RedactingLog,
        makeIdentitySource: @escaping @Sendable (AccountProvider) -> any ProviderIdentityFetching,
        phaseDidProject: @escaping @MainActor @Sendable (AccountFlowPhase) -> Void = { _ in }
    ) {
        self.catalog = catalog
        self.store = store
        self.vault = vault
        self.providerSuites = providerSuites
        self.browser = browser
        self.monotonic = monotonic
        self.log = log
        self.makeIdentitySource = makeIdentitySource
        self.phaseDidProject = phaseDidProject
    }

    func consumeConnectedAnnouncement() -> AccountID? {
        defer { pendingConnectedAnnouncement = nil }
        return pendingConnectedAnnouncement
    }

    func beginAddFlow() {
        guard accountChangesAreOpen else { return }
        clearNonrenderableCancelledFlowIfNeeded()
        guard activeFlow == nil else { return }

        beginProviderIdentityBackfill()
        addFlowRefusal = nil

        context = FlowContext(
            purpose: .add,
            provider: nil,
            accountID: nil,
            name: nil,
            reservationHeld: false
        )
        activeFlowProvider = nil
        setPhase(.naming)
    }

    /// Starts adding an account, or says why it did not.
    ///
    /// It answers for the reason `removeAccount` and `beginReauth` answer: the answer is what the
    /// naming step announces, and under warnings-as-errors a caller cannot drop it, so a further
    /// guard cannot be added here without a case and a sentence. `addFlowRefusal` stays — it is
    /// the observable the step draws its caption from, and it outlives the press.
    func submitAdd(name: String, provider: AccountProvider) -> AddFlowRefusal? {
        guard accountChangesAreOpen else {
            return refuseAddSubmission(.accountChangesAreClosed)
        }
        // Neither of the next two is reachable from the only control that reaches this. Continue
        // exists on the naming step of an add and nowhere else, and it is disabled while the name
        // is empty. An answer here would be a sentence announced to a user who pressed nothing.
        guard case .some(.naming) = activeFlow, context?.purpose == .add else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        addFlowRefusal = nil

        context?.name = trimmedName
        context?.provider = provider
        activeFlowProvider = provider

        do {
            let pendingID = try catalog.reserveAddSlot(
                name: trimmedName,
                provider: provider
            )
            context?.accountID = pendingID
            context?.reservationHeld = true
        } catch AccountCatalogError.accountLimitReached {
            context?.provider = nil
            activeFlowProvider = nil
            setPhase(.naming)
            addFlowRefusal = .accountLimitReached
            return .accountLimitReached
        } catch AccountCatalogError.catalogUnreadable {
            return refuseAddSubmission(.accountListUnreadable)
        } catch {
            return refuseAddSubmission(.accountCouldNotBeReserved)
        }

        setPhase(.starting)
        startAttempt()
        return nil
    }

    /// Signs one account in again, or says why it did not.
    ///
    /// Each refusal answers with its cause, so the card can say why instead of keeping its
    /// "Sign in required" well and a button that changes nothing. This is the control a user
    /// presses only because something has already gone wrong, so a dead button confirms the app
    /// is broken.
    ///
    /// Four answers for four guards. See `AccountReconnectRefusal`.
    func beginReauth(_ id: AccountID) -> AccountReconnectRefusal? {
        guard accountChangesAreOpen else {
            return .accountChangesAreClosed
        }
        clearNonrenderableCancelledFlowIfNeeded()
        guard activeFlow == nil else { return .anotherAccountFlowIsOpen }
        guard catalog.loadState != .unreadable else { return .accountListUnreadable }
        guard let account = catalog.accounts.first(where: { $0.id == id }) else {
            return .accountIsNoLongerListed
        }
        beginProviderIdentityBackfill()
        context = FlowContext(
            purpose: .reauthenticate,
            provider: account.provider,
            accountID: id,
            name: nil,
            reservationHeld: false
        )
        activeFlowProvider = account.provider
        setPhase(.starting)
        startAttempt()
        return nil
    }

    func cancelActiveFlow(_ reason: FlowDismissalReason) {
        guard let phase = activeFlow else { return }
        if case .failed = phase {
            clearFlow()
            return
        }

        switch reason {
        case .userCancel, .escape, .quit:
            flowTask?.cancel()
            browserOpenTask?.cancel()
            releaseReservationIfNeeded()
            clearFlow()
        }
    }

    func acknowledgeFailure() {
        guard let phase = activeFlow else { return }
        guard case .failed = phase else {
            assertionFailure("A live account flow cannot be acknowledged as a failure.")
            return
        }
        clearFlow()
    }

    func retryActiveFlow() {
        guard case .some(.failed) = activeFlow,
              accountChangesAreOpen,
              retryIsAllowedNow() else {
            return
        }
        restartTerminalFlow()
    }

    func requestNewDeviceCode() {
        guard activeFlowProvider == .openai,
              accountChangesAreOpen,
              retryIsAllowedNow() else {
            return
        }

        switch activeFlow {
        case .some(.openAIAwaitingDevice):
            replaceLiveDeviceCodeAttempt()
        case .some(.failed(.deadlineExpired)),
             .some(.failed(.startFailed)):
            restartTerminalFlow()
        default:
            return
        }
    }

    func reopenAuthorizationBrowser() {
        guard accountChangesAreOpen,
              activeFlowProvider == .anthropic,
              case .some(.anthropicWaitingInBrowser(let authorizationURL)) = activeFlow,
              browserOpenTask == nil else {
            return
        }

        let identifier = UUID()
        browserOpenTaskIdentifier = identifier
        let browser = self.browser
        browserOpenTask = Task { @MainActor [weak self] in
            _ = await browser.open(authorizationURL)
            self?.browserOpenDidFinish(identifier)
        }
    }

    /// Removes one account, or says why it did not.
    ///
    /// Each of the four refusals answers with its cause, so the panel does not close its
    /// confirmation and leave the row exactly where it was. One of the four is invisible from the
    /// panel: a quit that has already closed account changes, in which case Remove looks live and
    /// does nothing. See `AccountRemovalRefusal`.
    func removeAccount(_ id: AccountID) -> AccountRemovalRefusal? {
        guard accountChangesAreOpen else {
            return .accountChangesAreClosed
        }
        guard catalog.loadState != .unreadable else { return .accountListUnreadable }
        guard catalog.accounts.contains(where: { $0.id == id }) else { return .accountAlreadyRemoved }
        if context?.purpose == .reauthenticate,
           context?.accountID == id {
            cancelActiveFlow(.userCancel)
        }

        catalog.remove(id)
        store.reconcile(accounts: catalog.accounts, reauthenticated: [:])

        guard !catalog.accounts.contains(where: { $0.id == id }) else {
            return .removalWasNotApplied
        }

        let removalIdentifier = UUID()
        let vault = self.vault
        removalTasks[removalIdentifier] = Task { @MainActor [weak self] in
            var deleted = false
            defer {
                self?.removalDidFinish(
                    removalIdentifier,
                    accountID: id,
                    deleted: deleted
                )
            }
            do {
                // The vault ends the grant at the provider on its way out. Nothing here waits on
                // that answer or reads it: the row is already gone from the list, and a network
                // that will not answer never keeps a credential on this Mac.
                try await vault.deleteTokens(for: id)
                deleted = true
            } catch {
                // Removal has no failure carrier by contract, and it does not need one: the
                // account's metadata is already gone. The identity is kept so the quit can try
                // the delete once more, and startup reconciliation sweeps whatever is left.
            }
        }
        return nil
    }

    /// Closes account changes for good and waits, bounded, for the deletions already in flight.
    ///
    /// The close is one-way, because this runs on the way out of the process. Nothing here can
    /// refuse the quit: an unfinished delete is a Keychain item with no account row, which the
    /// next launch's reconciliation sweeps. What the wait buys is the ordinary case — a removal
    /// pressed a moment before Command-Q finishes removing, instead of leaving a credential
    /// behind on a Mac whose owner may never open the app again.
    func beginOrdinaryShutdown(
        timeout: Duration = TERMINATION_DRAIN_TIMEOUT
    ) async {
        accountChangesAreClosedForQuit = true
        identityBackfillTask?.cancel()
        cancelActiveFlow(.quit)

        let removalsAtBoundary = Array(removalTasks.values)
        let drain = Task { @MainActor [weak self] in
            for removal in removalsAtBoundary {
                await removal.value
            }
            await self?.retryPendingCredentialDeletions()
        }
        _ = await awaitWithinTerminationDeadline(timeout, { await drain.value })
    }

    private func retryPendingCredentialDeletions() async {
        let pendingDeletionIDs = pendingCredentialDeletionIDs.sorted {
            $0.rawValue.uuidString < $1.rawValue.uuidString
        }
        for accountID in pendingDeletionIDs {
            do {
                try await vault.deleteTokens(for: accountID)
                pendingCredentialDeletionIDs.remove(accountID)
            } catch {
                // Still on the device. The account row is already gone, so what is left is an
                // orphan credential, and the next launch's reconciliation sweeps exactly those.
            }
        }
    }

    private func startAttempt() {
        guard let provider = context?.provider,
              let accountID = context?.accountID,
              let purpose = context?.purpose,
              let suite = providerSuites[provider],
              suite.provider == provider else {
            failBeforeTask(.storeFailed)
            return
        }

        let acquirer = suite.makeAcquirer()
        guard acquirer.provider == provider else {
            failBeforeTask(.storeFailed)
            return
        }

        let request = CredentialStoreRequest(
            accountID: accountID,
            provider: provider,
            purpose: purpose
        )
        let channel = startChannel()
        startDriving(
            request,
            acquirer: acquirer,
            channel: channel,
            after: nil
        )
    }

    private func startDriving(
        _ request: CredentialStoreRequest,
        acquirer: any OAuthTokenAcquirer,
        channel: Channel,
        after retiringTask: Task<Void, Never>?
    ) {
        let task = Task { @MainActor [weak self] in
            defer {
                self?.flowTaskDidFinish(channel.id)
            }

            if let retiringTask {
                // The retiring attempt is always cancelled before it gets here, but cancellation
                // is a request: an acquirer already inside a browser round trip ends when its own
                // deadline says so, and until then a bare `await retiringTask.value` would hold
                // *this* attempt suspended even after it had been cancelled too. `joinFlight`
                // exists for that shape, and it is what makes the guard below reachable promptly.
                try? await joinFlight(retiringTask)
                guard !Task.isCancelled,
                      let self,
                      channel.id == self.attempt else {
                    return
                }
                await self.drive(
                    request,
                    acquirer: acquirer,
                    channel: channel
                )
                return
            }

            guard let self else { return }
            await self.drive(
                request,
                acquirer: acquirer,
                channel: channel
            )
        }
        flowTaskAttempt = channel.id
        flowTask = task
    }

    private func drive(
        _ request: CredentialStoreRequest,
        acquirer: any OAuthTokenAcquirer,
        channel: Channel
    ) async {
        do {
            let receipt = try await vault.performStore(
                request,
                using: acquirer,
                report: channel.report
            )
            let identity = await fetchProviderIdentity(
                for: receipt.accountID,
                provider: receipt.provider
            )
            if let identity,
               let collision = ProviderIdentityEnrollment.existingAccount(
                   matching: identity,
                   provider: receipt.provider,
                   in: catalog.accounts,
                   excluding: receipt.accountID
               ) {
                await discardDuplicateGrant(receipt, purpose: request.purpose)
                finishFailed(
                    .alreadyConnected(accountName: collision.name),
                    channel: channel
                )
                return
            }
            finishConnected(receipt, identity: identity, channel: channel)
        } catch let error as OAuthLoginError {
            finishFailed(mapLogin(error), channel: channel)
        } catch let error as TokenVaultError {
            finishFailed(mapVault(error), channel: channel)
        } catch is CancellationError {
            finishFailed(.cancelled, channel: channel)
        } catch {
#if DEBUG
            assertionFailure("performStore threw outside its closed error vocabulary: \(type(of: error))")
#endif
            log.emit(
                DiagEvent(
                    provider: nil,
                    operation: .performStore,
                    outcome: .contractViolation,
                    machineErrorCode: "performStore_unexpected_error_type"
                )
            )
            finishFailed(.storeFailed, channel: channel)
        }
    }

    /// Finalises a successful attempt in one synchronous segment with no suspension point.
    ///
    /// The guard and the segment are one atomic step because nothing between them can suspend.
    /// Phase delivery is inline, so there is no queue to drain: no gap opens between the check and
    /// the commit, and one `channel.id == attempt` check is enough.
    private func finishConnected(
        _ receipt: CredentialStoreReceipt,
        identity: ProviderAccountIdentity?,
        channel: Channel
    ) {
        guard channel.id == attempt else { return }
        closePhaseChannel(channel)
        guard let purpose = context?.purpose else {
            assertionFailure("A current account-flow terminal has no context.")
            return
        }

        do {
            switch purpose {
            case .add:
                try catalog.finalizeAdd(
                    receipt.accountID,
                    revision: receipt.revision
                )
            case .reauthenticate:
                catalog.markConnected(
                    receipt.accountID,
                    revision: receipt.revision
                )
            }
            // After the row exists, and only if the provider actually answered. An account whose
            // identity stayed unknown is a normal account; it simply cannot take part in the
            // duplicate check until someone asks again.
            if let identity {
                catalog.recordProviderIdentity(identity, for: receipt.accountID)
            }
            context?.reservationHeld = false
            store.reconcile(
                accounts: catalog.accounts,
                reauthenticated: purpose == .reauthenticate
                    ? [receipt.accountID: receipt.revision]
                    : [:]
            )
            pendingConnectedAnnouncement = receipt.accountID
            clearFlow()
        } catch {
            releaseReservationIfNeeded()
            setPhase(.failed(.storeFailed))
        }
    }

    private func finishFailed(
        _ failure: AccountFlowFailure,
        channel: Channel
    ) {
        guard channel.id == attempt else { return }
        closePhaseChannel(channel)
        releaseReservationIfNeeded()
        setPhase(.failed(failure))
    }

    /// Asks the provider which of the user's accounts one grant belongs to.
    ///
    /// The answer is what makes "you have already added this account" sayable, and it is a
    /// courtesy rather than a gate: every failure here returns nil and the sign-in goes through.
    /// Refusing an add because a profile request timed out would block a legitimate account over
    /// a network blip, and a row with no identity is a state the app already supports.
    ///
    /// Anthropic costs one GET to `/api/oauth/profile`. ChatGPT costs no request at all, because
    /// the grant already carries the account id.
    private func fetchProviderIdentity(
        for accountID: AccountID,
        provider: AccountProvider
    ) async -> ProviderAccountIdentity? {
        let vault = self.vault
        let source = makeIdentitySource(provider)
        let work = Task {
            guard let token = try? await vault.getValidToken(accountID: accountID) else {
                return ProviderAccountIdentity?.none
            }
            return try? await source.fetchIdentity(token: token)
        }
        defer { work.cancel() }
        let answered = await awaitWithinTerminationDeadline(
            Self.providerIdentityDeadline,
            { await work.value }
        )
        return answered ?? nil
    }

    /// Asks the provider who each identity-less account belongs to, in the background.
    ///
    /// Rows an update inherits carry no provider identity, and a row with no identity cannot take
    /// part in the duplicate check — so on the first add after an update the check would have
    /// nothing to compare against. This starts when a flow starts, which is many seconds before a
    /// grant comes back from a browser or a device code, so the answers are in place by the time
    /// they are read. Nothing waits for it.
    private func beginProviderIdentityBackfill() {
        guard identityBackfillTask == nil else { return }
        let awaiting = ProviderIdentityEnrollment.awaitingIdentity(in: catalog.accounts)
        guard !awaiting.isEmpty else { return }

        identityBackfillTask = Task { @MainActor [weak self] in
            for account in awaiting {
                if Task.isCancelled { break }
                guard let self else { return }
                if let identity = await self.fetchProviderIdentity(
                    for: account.id,
                    provider: account.provider
                ) {
                    self.catalog.recordProviderIdentity(identity, for: account.id)
                }
            }
            self?.identityBackfillTask = nil
        }
    }

    /// Undoes the grant that turned out to be a second sign-in to an account already here.
    ///
    /// The credential was committed before the provider could be asked whose account it is —
    /// `performStore` mints and stores in one step — so undoing it is a real delete, and the
    /// vault ends the grant at the provider on its way out.
    ///
    /// A reconnect is the harder half. It has already replaced one account's credential with a
    /// grant for somebody else's account, and the credential it replaced is gone. So the row is
    /// left in the state that is true and that the user can act on: this account needs signing
    /// in again.
    private func discardDuplicateGrant(
        _ receipt: CredentialStoreReceipt,
        purpose: CredentialStorePurpose
    ) async {
        try? await vault.deleteTokens(for: receipt.accountID)
        guard purpose == .reauthenticate else { return }
        catalog.markNeedsReauthentication(receipt.accountID, failedRevision: nil)
        store.reconcile(accounts: catalog.accounts, reauthenticated: [:])
    }

    private func mapLogin(_ error: OAuthLoginError) -> AccountFlowFailure {
        switch error {
        case .browserOpenFailed:
            .browserOpenFailed
        case .startFailed(let failure):
            .startFailed(failure)
        case .deadlineExpired:
            .deadlineExpired
        case .denied:
            .denied
        case .listenerUnavailable:
            .listenerUnavailable
        case .exchangeFailed:
            .exchangeFailed
        case .scopeNotGranted:
            .scopeNotGranted
        }
    }

    private func mapVault(_ error: TokenVaultError) -> AccountFlowFailure {
        switch error {
        case .credentialStoreInProgress, .providerMismatch:
            return .storeFailed
        case .accountRemoved:
            return .cancelled
        case .storageTemporarilyUnavailable:
            return .storageUnavailable
        case .temporarilyUnavailable,
             .credentialUnavailable,
             .credentialCorrupt,
             .reauthenticationRequired:
#if DEBUG
            assertionFailure("performStore threw a refresh-path-only TokenVaultError.")
#endif
            log.emit(
                DiagEvent(
                    provider: nil,
                    operation: .performStore,
                    outcome: .contractViolation,
                    machineErrorCode: "performStore_refresh_only_error"
                )
            )
            return .storeFailed
        }
    }

    private func startChannel() -> Channel {
        precondition(attempt != .max, "Account flow attempt identifier exhausted.")
        attempt += 1

        let mine = attempt
        openPhaseChannel = mine
        return Channel(
            id: mine,
            report: { [weak self] phase in
                self?.deliverPhase(phase, from: mine)
            }
        )
    }

    /// Applies one reported phase where it arrives.
    ///
    /// The identity check is the channel rather than the attempt because it answers both questions
    /// at once: whether this attempt is still the current one, and whether its channel is still
    /// open. A closed channel belongs to an attempt that has begun finalising, and a phase from it
    /// would land on top of the state finalisation is writing.
    private func deliverPhase(_ phase: AccountFlowPhase, from channelID: UInt64) {
        guard openPhaseChannel == channelID else { return }
        setPhase(phase)
        phaseDidProject(phase)
    }

    private func closePhaseChannel(_ channel: Channel) {
        guard openPhaseChannel == channel.id else { return }
        openPhaseChannel = nil
    }

    /// Writes a reported phase into the live flow, except the one that is not a state.
    ///
    /// `.connected` is transient by declaration — see the case's own comment in `AuthFlow.swift`.
    /// It is reported and projected like every other phase, and it is never left in `activeFlow`,
    /// because the finalize that follows it appends the row and sets the announcement, and those
    /// two together are the success signal. A `.connected` sitting in the flow would be a success
    /// step drawn over the account list it just added to.
    ///
    /// This is where that rule is enforced, and
    /// `AddFlowPhaseDeliveryTests.connectedPhaseIsObservableButTransient` is where it is proven.
    /// Nothing downstream depends on it: the panel decides from what a phase renders, so a
    /// `.connected` that did reach `activeFlow` would leave every surface where it stood.
    private func setPhase(_ phase: AccountFlowPhase) {
        guard context != nil else { return }
        if case .connected = phase { return }

        activeFlow = phase
    }

    /// Puts the naming step back with a reason, instead of taking the form away.
    ///
    /// What the user supplied is theirs. The name they typed and the provider they picked live in
    /// the naming step's own state, and they last exactly as long as the step is on screen.
    /// `clearFlow()` takes the step off the screen, so clearing on a refusal would cost the user
    /// their typing and tell them nothing. Pressing Continue is not a mistake the user should have
    /// to pay for by typing it all again.
    ///
    /// Only the coordinator's record of an attempt that never started is unwound here. No slot
    /// was reserved on any of these paths, so there is no reservation to release.
    ///
    /// The five-account cap does the same thing a few lines above, written out rather than routed
    /// through here, because a source scan in the panel suite counts that assignment by name.
    /// Returns the refusal it recorded, so the caller answers the press with the same value the
    /// step draws its caption from. Two writes of one fact could disagree; one value cannot.
    private func refuseAddSubmission(_ refusal: AddFlowRefusal) -> AddFlowRefusal {
        context?.provider = nil
        activeFlowProvider = nil
        setPhase(.naming)
        addFlowRefusal = refusal
        return refusal
    }

    private func clearFlow() {
        precondition(attempt != .max, "Account flow attempt identifier exhausted.")
        attempt += 1
        openPhaseChannel = nil
        flowTask = nil
        flowTaskAttempt = nil
        browserOpenTask?.cancel()
        browserOpenTask = nil
        browserOpenTaskIdentifier = nil
        context = nil
        activeFlow = nil
        activeFlowProvider = nil
        addFlowRefusal = nil
    }

    private func releaseReservationIfNeeded() {
        guard context?.purpose == .add,
              context?.reservationHeld == true,
              let accountID = context?.accountID else {
            return
        }
        catalog.releaseReservation(accountID)
        context?.reservationHeld = false
        context?.accountID = nil
    }

    private func restartTerminalFlow() {
        guard let flowContext = context,
              let provider = flowContext.provider else {
            return
        }

        switch flowContext.purpose {
        case .add:
            guard let name = flowContext.name else {
                clearFlow()
                return
            }
            do {
                let pendingID = try catalog.reserveAddSlot(
                    name: name,
                    provider: provider
                )
                context?.accountID = pendingID
                context?.reservationHeld = true
            } catch AccountCatalogError.accountLimitReached {
                context?.provider = nil
                activeFlowProvider = nil
                setPhase(.naming)
                addFlowRefusal = .accountLimitReached
                return
            } catch {
                clearFlow()
                return
            }
        case .reauthenticate:
            guard let accountID = flowContext.accountID,
                  catalog.accounts.contains(where: {
                      $0.id == accountID && $0.provider == provider
                  }) else {
                clearFlow()
                return
            }
        }

        activeFlowProvider = provider
        setPhase(.starting)
        startAttempt()
    }

    private func replaceLiveDeviceCodeAttempt() {
        guard let flowContext = context,
              flowContext.provider == .openai,
              let accountID = flowContext.accountID,
              let suite = providerSuites[.openai],
              suite.provider == .openai else {
            return
        }

        let acquirer = suite.makeAcquirer()
        guard acquirer.provider == .openai else { return }

        let retiringTask = flowTask
        retiringTask?.cancel()
        browserOpenTask?.cancel()
        setPhase(.starting)
        let channel = startChannel()
        let request = CredentialStoreRequest(
            accountID: accountID,
            provider: .openai,
            purpose: flowContext.purpose
        )
        startDriving(
            request,
            acquirer: acquirer,
            channel: channel,
            after: retiringTask
        )
    }

    // The gate the user sees and the gate this type enforces are the SAME instant, read off the same failure.
    // Nothing here mirrors the deadline, so the two cannot disagree and no code has to keep them in step.
    private func retryIsAllowedNow() -> Bool {
        guard case .some(.failed(.startFailed(.rateLimited(.some(let retryAt))))) = activeFlow else { return true }
        return monotonic.now >= retryAt
    }

    private func failBeforeTask(_ failure: AccountFlowFailure) {
        releaseReservationIfNeeded()
        setPhase(.failed(failure))
    }

    private func clearNonrenderableCancelledFlowIfNeeded() {
        if case .some(.failed(.cancelled)) = activeFlow {
            clearFlow()
        }
    }

    private func flowTaskDidFinish(_ channelID: UInt64) {
        guard flowTaskAttempt == channelID else { return }
        flowTask = nil
        flowTaskAttempt = nil
    }

    private func browserOpenDidFinish(_ identifier: UUID) {
        guard browserOpenTaskIdentifier == identifier else { return }
        browserOpenTask = nil
        browserOpenTaskIdentifier = nil
    }

    private func removalDidFinish(
        _ identifier: UUID,
        accountID: AccountID,
        deleted: Bool
    ) {
        removalTasks[identifier] = nil
        if deleted {
            pendingCredentialDeletionIDs.remove(accountID)
        } else {
            pendingCredentialDeletionIDs.insert(accountID)
        }
    }

    private var accountChangesAreOpen: Bool { !accountChangesAreClosedForQuit }

    // Whether a dismissal acknowledges a terminal `.failed` is decided where the gesture still
    // exists: `MenuBarPanelController.hide(reason:)` knows why the panel is going, and
    // `panelDismissalAcknowledgesFailure` states which of the six reasons is the user saying they
    // are done. Panel visibility cannot answer it: opening Settings hides the panel, and the
    // system takes a `.transient` panel off screen by itself — Mission Control, a space change,
    // an occlusion — with no user gesture anywhere near it.
}
