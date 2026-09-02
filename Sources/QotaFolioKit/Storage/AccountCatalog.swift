import Foundation
import Observation
import QotaFolioCore

/// The catalog's durable commits are optimistic in memory and ordered on the wire.
///
/// A commit is `CatalogFileIO.writeCatalog`, which issues `F_FULLFSYNC` twice — once on the staging
/// file and once on the parent directory after the rename. Neither returns until the storage device
/// acknowledges a full cache flush. This type is `@MainActor`, so performing a commit inside a
/// mutator would run both device flushes on the main thread — and the automatic path is what makes
/// that critical: a token refresh reports its result through `AccountAuthorizationStateSink`, so an
/// unprompted hourly rotation would put two device flushes on the main thread of a menu-bar app.
///
/// The shape:
///
/// - Every mutator keeps its signature and applies its change to `accounts` immediately, so the UI
///   is never waiting on a disk.
/// - The durable write happens on `CatalogCommitWriter`, an actor with its own serial executor.
/// - Commits are strictly ordered by a chain on the MainActor, not by the writer. Swift promises
///   nothing about the order in which concurrent calls to an actor are serviced, so "an ordered
///   actor" would be a hope. Each commit task awaits its predecessor before it starts, so
///   only one commit is ever in flight and a later commit can never start before an earlier one's
///   outcome has been applied.
/// - The outcome is applied on the MainActor when it returns: rollback for `notReplaced`, quarantine
///   for `replacementDurabilityUncertain`. Because the chain guarantees the earlier outcome landed
///   first, a rollback is always computed against a state no later commit has superseded.
///
/// Reads are separate, and this type keeps two facts about them apart. `CatalogLoadResult`
/// distinguishes a catalog whose bytes are wrong from a read that never happened, and the
/// difference decides everything downstream: corrupt bytes are a durable verdict
/// the user must be told about, while a descriptor shortage or a directory with the wrong mode is a
/// fact about the machine that says nothing about the catalog. The first freezes the catalog for the
/// session; the second freezes it only until the next time the app looks. Neither ever shows an
/// empty account list, because "we could not read it" and "you have no accounts" are different
/// sentences and only one of them is ever true here.
@MainActor @Observable
public final class AccountCatalog: AccountCataloging, AccountAuthorizationStateSink {
    public private(set) var accounts: [AccountConfig]
    public private(set) var pendingReservationCount: Int
    public private(set) var loadState: CatalogLoadState
    public private(set) var recoveryAdvisory: CatalogRecoveryAdvisory?

    /// Reads only. `load()` stays synchronous and stays here: reading the catalog does not flush
    /// the device, and the composition root calls it before the UI exists.
    @ObservationIgnored private let store: any AccountCatalogPersisting
    @ObservationIgnored private let writer: CatalogCommitWriter
    @ObservationIgnored private let log: (any RedactingLog)?
    @ObservationIgnored private var reservations: [AccountID: Reservation]
    @ObservationIgnored private var lineage: [AccountID: CredentialRevision]

    /// The state the bytes on the device describe. Rollback and quarantine are computed against
    /// this, not against a per-mutation snapshot: with commits coalescing, "the state before this
    /// mutation" and "the state that is durable" stop being the same thing, and only the second one
    /// answers what the disk actually holds.
    @ObservationIgnored private var durableSnapshot: Snapshot

    /// The tail of the commit chain. `drainPendingCommits` awaits exactly this.
    @ObservationIgnored private var commitTask: Task<Void, Never>?

    /// Why the catalog is not serving durable state, and `nil` while it is.
    ///
    /// `CatalogLoadState.unreadable` is one word for three different situations, and they do
    /// not have the same answer. Corrupt bytes are a durable verdict; a read that never
    /// happened is not a verdict at all; a failed commit means the rows in memory are a
    /// repair that a re-read would destroy. Only the middle one may be retried, and nothing
    /// in `CatalogLoadState` can say which one this is, so the catalog remembers it.
    @ObservationIgnored private var quarantine: Quarantine?

    /// True while a commit is scheduled but has not yet captured the state it will write. Further
    /// mutations in that window need no commit of their own — the queued one will pick them up when
    /// it starts. This is what keeps a drag-reorder burst from costing one device flush per frame.
    @ObservationIgnored private var hasQueuedCommit: Bool

    /// One entry per mutation folded into the next commit, so the per-account persistence
    /// diagnostics stay one event per mutation even when several mutations share one write.
    @ObservationIgnored private var pendingCommitAttribution: [AccountID?]

    public init(
        store: any AccountCatalogPersisting,
        log: (any RedactingLog)? = nil
    ) {
        self.store = store
        writer = CatalogCommitWriter(store: store)
        self.log = log
        accounts = []
        pendingReservationCount = 0
        loadState = .loading
        recoveryAdvisory = nil
        reservations = [:]
        lineage = [:]
        durableSnapshot = Snapshot(accounts: [], lineage: [:])
        commitTask = nil
        quarantine = nil
        hasQueuedCommit = false
        pendingCommitAttribution = []
    }

    /// Reads the catalog, and reads it again when the last attempt never happened.
    ///
    /// Still synchronous, and deliberately so. Reading the catalog does not flush the device, and
    /// the composition root calls this before the UI exists.
    ///
    /// It re-reads for exactly one reason: **the previous attempt did not happen**. In every
    /// other state it is a no-op, which is what makes it safe to call whenever the app wants the
    /// catalog to reflect the device — the panel opening, a mutation being attempted, an
    /// authorization report arriving from the vault.
    ///
    /// It deliberately refuses to re-read after a durable verdict. Corrupt bytes read again are the
    /// same corrupt bytes. And after a failed commit the rows in memory are a rollback or an
    /// uncertain-commit projection; re-reading would silently discard the repair the commit path
    /// performed and replace it with whichever of the two possible catalogs happened to survive.
    public func load() {
        switch loadState {
        case .loading:
            break
        case .missing, .loaded:
            return
        case .unreadable:
            guard canRetryLoad else { return }
        }
        apply(store.load())
    }

    /// True when the last read did not happen and another attempt is meaningful.
    ///
    /// Internal, and published to the panel as `AccountCataloging.loadCanBeRetried`. It is the
    /// hook the recovery takeover needs, and the tests use it to prove the distinction is kept.
    var canRetryLoad: Bool {
        if case .readObstructed = quarantine { return true }
        return false
    }

    /// The catalog's answer to one read, applied.
    ///
    /// Each of the four outcomes gets a different response, because each is a different fact:
    ///
    /// - `.missing` and `.loaded` are the catalog answering. Any earlier quarantine is over.
    /// - `.corrupt` is DURABLE. The bytes were read and they are not a catalog. Freezing is right,
    ///   and the recovery advisory the composition root raises against `.unreadable` is what tells
    ///   the user the truth: the catalog is broken and the saved sign-ins survive.
    /// - `.temporarilyUnreadable` is NOT a verdict on the catalog. Nothing was learned about the
    ///   bytes, so nothing about them is claimed: no quarantine projection is built, no deletion is
    ///   authorised, and the next time the app needs the catalog it reads again.
    ///
    /// All four leave `accounts` unrenderable-as-truth on failure: the rows are hidden behind the
    /// account-list-unavailable takeover rather than shown as an empty catalog, because an empty
    /// list is a claim and it is the one claim a failed read cannot make.
    private func apply(_ result: CatalogLoadResult) {
        switch result {
        case .missing:
            accounts = []
            quarantine = nil
            loadState = .missing
            emitCatalogLoad(outcome: .ok, code: "catalog.missing")

        case .loaded(let records):
            accounts = Self.normalized(records.map { $0.makeAccountConfig() })
            quarantine = nil
            loadState = .loaded
            emitCatalogLoad(outcome: .ok, code: "catalog.loaded")

        case .corrupt:
            accounts = []
            freeze(.corruptCatalog)
            emitCatalogLoad(outcome: .permanent, code: "catalog.corrupt")

        case .temporarilyUnreadable(let obstruction):
            accounts = []
            freeze(.readObstructed(obstruction))
            switch obstruction {
            case .resourcesUnavailable:
                emitCatalogLoad(outcome: .transient, code: "catalog.read_obstructed")
            case .anchorUnusable:
                // An environment fault, reported as itself. The catalog file was never
                // examined: one directory has permissions this build refuses to write
                // through, or the anchor is not the container the manifest declares.
                emitCatalogLoad(outcome: .transient, code: "catalog.anchor_unusable")
            }
        }
        durableSnapshot = snapshot()
    }

    /// The only door to `.unreadable`.
    ///
    /// Every route into the frozen state records why it froze, so the two questions that depend on
    /// it — may the app read again, and may a re-read overwrite what is in memory — always have an
    /// answer. Assigning `loadState` directly would let a future caller freeze without one.
    private func freeze(_ reason: Quarantine) {
        quarantine = reason
        loadState = .unreadable
    }

    public func setRecoveryAdvisory(_ advisory: CatalogRecoveryAdvisory?) {
        recoveryAdvisory = advisory
    }

    public func reserveAddSlot(
        name: String,
        provider: AccountProvider
    ) throws -> AccountID {
        load()
        guard loadState != .unreadable else {
            throw AccountCatalogError.catalogUnreadable
        }
        guard accounts.count + pendingReservationCount < qotaFolioMaximumAccounts else {
            throw AccountCatalogError.accountLimitReached(
                maximum: qotaFolioMaximumAccounts
            )
        }

        let id = AccountID(rawValue: UUID())
        reservations[id] = Reservation(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider,
            reference: CredentialReference(accountID: id)
        )
        pendingReservationCount = reservations.count
        return id
    }

    /// Throws for the failure it can answer now — a catalog that is already unreadable. It cannot
    /// throw for the commit it is scheduling, because that answer is two device flushes away and
    /// this call must not hold the main thread waiting for them. A commit that fails afterwards
    /// rolls the row back and flips `loadState` to `.unreadable`, which the panel renders as the
    /// account-list-unavailable takeover.
    public func finalizeAdd(
        _ pendingID: AccountID,
        revision: CredentialRevision
    ) throws {
        load()
        guard loadState != .unreadable else {
            throw AccountCatalogError.catalogUnreadable
        }
        guard let reservation = reservations[pendingID] else { return }

        reservations.removeValue(forKey: pendingID)
        pendingReservationCount = reservations.count
        accounts.append(
            AccountConfig(
                id: pendingID,
                name: reservation.name,
                provider: reservation.provider,
                credentialReference: reservation.reference,
                displayOrder: accounts.count,
                authorizationState: .connected
            )
        )
        accounts = Self.normalized(accounts)
        lineage[pendingID] = revision
        scheduleCommit(attributedTo: pendingID)
    }

    public func releaseReservation(_ pendingID: AccountID) {
        guard reservations.removeValue(forKey: pendingID) != nil else { return }
        pendingReservationCount = reservations.count
    }

    public func remove(_ id: AccountID) {
        load()
        guard loadState != .unreadable,
              accounts.contains(where: { $0.id == id }) else {
            return
        }

        accounts.removeAll { $0.id == id }
        accounts = Self.normalized(accounts)
        lineage.removeValue(forKey: id)
        scheduleCommit(attributedTo: id)
    }

    public func rename(_ id: AccountID, to name: String) {
        load()
        guard loadState != .unreadable else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == id }),
              accounts[index].name != trimmed else {
            return
        }

        accounts[index].name = trimmed
        scheduleCommit(attributedTo: id)
    }

    public func reorder(_ orderedIDs: [AccountID]) {
        load()
        guard loadState != .unreadable,
              orderedIDs.count == accounts.count,
              Set(orderedIDs).count == orderedIDs.count,
              Set(orderedIDs) == Set(accounts.map(\.id)) else {
            return
        }

        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let reordered = orderedIDs.enumerated().compactMap { offset, id -> AccountConfig? in
            guard var account = byID[id] else { return nil }
            account.displayOrder = offset
            return account
        }
        guard reordered.count == accounts.count, reordered != accounts else { return }

        accounts = reordered
        scheduleCommit(attributedTo: nil)
    }

    /// Records which provider account a row's grant belongs to.
    ///
    /// Written when the provider has just answered for this grant, so a later add can be told it
    /// is the same account. A row that already carries the same identity is left alone, because
    /// rewriting it would schedule a durable commit for a fact that did not change.
    public func recordProviderIdentity(
        _ identity: ProviderAccountIdentity,
        for id: AccountID
    ) {
        load()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        guard accounts[index].providerIdentity != identity else { return }

        accounts[index].providerIdentity = identity
        guard loadState != .unreadable else { return }
        scheduleCommit(attributedTo: id)
    }

    public func markConnected(_ id: AccountID, revision: CredentialRevision) {
        load()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }

        accounts[index].authorizationState = .connected
        lineage[id] = revision
        guard loadState != .unreadable else { return }
        scheduleCommit(attributedTo: id)
    }

    public func markNeedsReauthentication(
        _ id: AccountID,
        failedRevision: CredentialRevision?
    ) {
        load()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }

        if let failedRevision,
           let currentRevision = lineage[id],
           currentRevision != failedRevision {
            return
        }

        accounts[index].authorizationState = .needsReauthentication(
            failedRevision: failedRevision
        )
        guard loadState != .unreadable else { return }
        scheduleCommit(attributedTo: id)
    }

    // MARK: - AccountAuthorizationStateSink

    /// The vault's report. Awaiting it awaits the durable commit, which is what keeps the refresh
    /// flight alive until the rotation it performed is on the device — and therefore what puts the
    /// commit inside the quiescence drain that quit and uninstall already await.
    public func recordConnected(_ id: AccountID, revision: CredentialRevision) async {
        markConnected(id, revision: revision)
        await drainPendingCommits()
    }

    public func recordNeedsReauthentication(
        _ id: AccountID,
        failedRevision: CredentialRevision?
    ) async {
        markNeedsReauthentication(id, failedRevision: failedRevision)
        await drainPendingCommits()
    }

    /// Waits for the durable outcome of every commit scheduled before this call.
    ///
    /// The tail is read once, synchronously, so this waits for a fixed amount of work and cannot be
    /// starved by mutations that arrive while it waits. The commit chain is unstructured and its
    /// failure type is `Never`, so cancelling the caller does not abandon a commit mid-flush —
    /// which is the behaviour durability requires, and the exact opposite of what a shared refresh
    /// flight requires from its waiters.
    public func drainPendingCommits() async {
        await commitTask?.value
    }

    // MARK: - Ordered commit chain

    private func scheduleCommit(attributedTo accountID: AccountID?) {
        pendingCommitAttribution.append(accountID)
        guard !hasQueuedCommit else { return }
        hasQueuedCommit = true

        let previous = commitTask
        commitTask = Task { @MainActor [self] in
            // Strictly ordered: this commit cannot reach the writer before the previous commit's
            // outcome has been applied. `self` is captured strongly on purpose — an in-flight
            // durable commit must outlive every other reference to the catalog. The chain always
            // terminates, so this is a temporary reference, not a cycle.
            await previous?.value
            await runNextCommit()
        }
    }

    private func runNextCommit() async {
        // No suspension point between here and the `await` below, so the records, the attribution
        // and the durable baseline are one consistent capture: no mutation can interleave, and any
        // mutation that arrives after this point schedules its own commit behind this one.
        hasQueuedCommit = false
        let attribution = pendingCommitAttribution
        pendingCommitAttribution = []

        guard loadState != .unreadable else {
            // An earlier commit in this chain failed and froze the catalog. The bytes this commit
            // would write were computed on top of a mutation now known not to have landed, so
            // writing them would make the device disagree with what the app decided.
            for accountID in attribution {
                emitCatalogPersist(
                    outcome: .refused,
                    code: "catalog.commit_abandoned",
                    accountID: accountID
                )
            }
            return
        }

        let pending = snapshot()
        let baseline = durableSnapshot
        let records = pending.accounts.map(AccountRecord.init(config:))

        switch await writer.commit(records) {
        case .committed:
            if loadState == .missing { loadState = .loaded }
            durableSnapshot = pending
            for accountID in attribution {
                emitCatalogPersist(
                    outcome: .ok,
                    code: "catalog.persisted",
                    accountID: accountID
                )
            }

        case .notReplaced(let error):
            // The previous catalog is provably intact, so the optimistic state is simply wrong.
            restore(baseline)
            freeze(.commitFailed)
            for accountID in attribution {
                switch error {
                case .encoding:
                    assertionFailure("QotaFolio catalog DTO encoding failed.")
                    emitCatalogPersist(
                        outcome: .contractViolation,
                        code: "catalog.encoding",
                        accountID: accountID
                    )
                case .write:
                    emitCatalogPersist(
                        outcome: .transient,
                        code: "catalog.write",
                        accountID: accountID
                    )
                }
            }

        case .replacementDurabilityUncertain:
            // Neither "old" nor "new" can be claimed, so neither may be shown as fact.
            enterUncertainCommitQuarantine(
                previous: baseline,
                replacement: pending.accounts
            )
            freeze(.commitFailed)
            for accountID in attribution {
                emitCatalogPersist(
                    outcome: .transient,
                    code: "catalog.commit_uncertain",
                    accountID: accountID
                )
            }
        }
    }

    /// Restores only what a catalog commit describes: the rows and their credential lineage.
    ///
    /// Reservations are deliberately left alone. They are memory-only bookkeeping owned by the add
    /// flow, they are never part of the durable bytes, and the coordinator releases the one it holds
    /// on its own terminal path. Restoring them from a durable baseline would resurrect a
    /// reservation the add flow has already let go of, and it would count against the five-account
    /// cap for the rest of the session.
    private func restore(_ snapshot: Snapshot) {
        accounts = snapshot.accounts
        lineage = snapshot.lineage
    }

    private func enterUncertainCommitQuarantine(
        previous: Snapshot,
        replacement: [AccountConfig]
    ) {
        let replacementByID = Dictionary(
            uniqueKeysWithValues: replacement.map { ($0.id, $0) }
        )
        var projection: [AccountConfig] = []

        for priorAccount in previous.accounts {
            if let replacementAccount = replacementByID[priorAccount.id] {
                if replacementAccount == priorAccount {
                    projection.append(priorAccount)
                }
                continue
            }

            var deletionGuard = priorAccount
            deletionGuard.authorizationState = .needsReauthentication(failedRevision: nil)
            projection.append(deletionGuard)
        }

        // This projection contains only facts shared by both possible durable
        // catalogs, plus non-authoritative deletion guards for rows whose removal
        // is uncertain. It is never persisted: `.unreadable` freezes every durable
        // mutation, and a fresh launch re-reads whichever catalog survived.
        accounts = Self.normalized(projection)
        lineage = [:]
    }

    private func snapshot() -> Snapshot {
        Snapshot(accounts: accounts, lineage: lineage)
    }

    private static func normalized(_ source: [AccountConfig]) -> [AccountConfig] {
        source
            .sorted {
                if $0.displayOrder != $1.displayOrder {
                    return $0.displayOrder < $1.displayOrder
                }
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
            .enumerated()
            .map { offset, value in
                var account = value
                account.displayOrder = offset
                return account
            }
    }

    private func emitCatalogLoad(outcome: DiagOutcome, code: StaticString) {
        log?.emit(
            DiagEvent(
                provider: nil,
                operation: .catalogLoad,
                outcome: outcome,
                machineErrorCode: code
            )
        )
    }

    private func emitCatalogPersist(
        outcome: DiagOutcome,
        code: StaticString,
        accountID: AccountID?
    ) {
        log?.emit(
            DiagEvent(
                provider: nil,
                operation: .catalogPersist,
                outcome: outcome,
                machineErrorCode: code,
                accountHash: accountID.map(redactedAccountHash)
            )
        )
    }

    /// Why the catalog stopped serving durable state.
    ///
    /// The three reasons are not shades of one failure. They differ in what is known and therefore
    /// in what may be done next.
    private enum Quarantine: Equatable {
        /// The bytes were read and they are not a catalog this build can trust. Reading them again
        /// produces the same verdict, so there is nothing to retry and the user must be told.
        case corruptCatalog

        /// The read did not happen: a resource was unavailable, or the anchor directory is not one
        /// this build may use. Nothing is known about the catalog, so nothing about it is claimed —
        /// and a later attempt, once the cause clears, is the way back.
        case readObstructed(CatalogReadObstruction)

        /// A durable commit failed. Memory and device disagree, and the rows in memory are the
        /// repair for that disagreement — a rollback to what is durable, or a projection of the
        /// facts both possible catalogs share. A re-read would discard it, so this never retries.
        case commitFailed
    }

    private struct Reservation: Sendable {
        let name: String
        let provider: AccountProvider
        let reference: CredentialReference
    }

    /// Exactly what a catalog commit describes. Not `loadState`, not `recoveryAdvisory` and not
    /// the reservation bookkeeping: none of them is durable, and none is read back on a rollback
    /// path.
    private struct Snapshot: Sendable {
        let accounts: [AccountConfig]
        let lineage: [AccountID: CredentialRevision]
    }
}
