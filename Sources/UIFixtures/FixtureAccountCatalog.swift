import Foundation
import Observation
import QotaFolioCore

/// What a fixture catalog does when the durable commit behind a mutation fails.
///
/// Production `AccountCatalog` can fail to persist; a fixture that never can teaches a
/// UI test that `finalizeAdd` always succeeds, which is not true of the app.
public nonisolated enum FixtureCatalogPersistOutcome: Sendable {
    case succeeds
    case failsCatalogUnreadable
}

/// The UI truth source for the account catalog.
///
/// Every validation rule here mirrors `QotaFolioKit.AccountCatalog`: names are trimmed,
/// blank renames are rejected, no-op writes are skipped, reorders must be a permutation of
/// the current rows, and a failed commit quarantines the catalog and throws. A divergence
/// would teach the UI and scenario suites to accept behaviour the app does not have.
@MainActor @Observable public final class FixtureAccountCatalog: AccountCataloging {
    /// The account cap. One declaration, read by both sites that enforce it.
    ///
    /// Production still spells `5` in `QotaFolioKit/Storage/AccountCatalog.swift`; until that
    /// literal reads a shared constant in `QotaFolioCore`, this is the fixture's single source.
    public static let maximumAccounts = 5

    public private(set) var accounts: [AccountConfig]
    public private(set) var pendingReservationCount: Int
    public private(set) var loadState: CatalogLoadState
    public private(set) var recoveryAdvisory: CatalogRecoveryAdvisory?

    /// Whether the next durable commit succeeds. Scenarios flip this to reach the
    /// `.unreadable` quarantine the app enters when a catalog write fails.
    public var persistOutcome: FixtureCatalogPersistOutcome

    /// Whether a further `load()` would read again — the fixture's stand-in for the production
    /// catalog's read-obstruction quarantine. Scenarios set it to reach the panel's
    /// temporarily-unreadable takeover, which is the one unreadable state that offers a retry.
    /// False by default, because a fixture that never reads a device never fails to read one.
    public var loadCanBeRetried = false

    @ObservationIgnored private var reservations: [AccountID: Reservation]
    @ObservationIgnored private var lineage: [AccountID: CredentialRevision]

    public init(
        accounts: [AccountConfig] = [],
        loadState: CatalogLoadState = .loaded,
        recoveryAdvisory: CatalogRecoveryAdvisory? = nil,
        persistOutcome: FixtureCatalogPersistOutcome = .succeeds
    ) {
        self.accounts = Self.normalized(accounts)
        self.pendingReservationCount = 0
        self.loadState = loadState
        self.recoveryAdvisory = recoveryAdvisory
        self.persistOutcome = persistOutcome
        self.reservations = [:]
        self.lineage = [:]
    }

    public func load() {
        guard loadState == .loading else { return }
        loadState = .loaded
    }

    public func setRecoveryAdvisory(_ advisory: CatalogRecoveryAdvisory?) {
        recoveryAdvisory = advisory
    }

    public func reserveAddSlot(name: String, provider: AccountProvider) throws -> AccountID {
        resolveLoadIfNeeded()
        guard loadState != .unreadable else { throw AccountCatalogError.catalogUnreadable }
        guard accounts.count + pendingReservationCount < Self.maximumAccounts else {
            throw AccountCatalogError.accountLimitReached(maximum: Self.maximumAccounts)
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

    public func finalizeAdd(_ pendingID: AccountID, revision: CredentialRevision) throws {
        resolveLoadIfNeeded()
        guard loadState != .unreadable else { throw AccountCatalogError.catalogUnreadable }
        guard let reservation = reservations[pendingID] else { return }

        let snapshot = snapshot()
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

        guard persistOrQuarantine(restoring: snapshot) else {
            throw AccountCatalogError.catalogUnreadable
        }
    }

    public func releaseReservation(_ pendingID: AccountID) {
        guard reservations.removeValue(forKey: pendingID) != nil else { return }
        pendingReservationCount = reservations.count
    }

    public func remove(_ id: AccountID) {
        resolveLoadIfNeeded()
        guard loadState != .unreadable,
              accounts.contains(where: { $0.id == id }) else {
            return
        }

        let snapshot = snapshot()
        accounts.removeAll { $0.id == id }
        accounts = Self.normalized(accounts)
        lineage.removeValue(forKey: id)
        _ = persistOrQuarantine(restoring: snapshot)
    }

    public func rename(_ id: AccountID, to name: String) {
        resolveLoadIfNeeded()
        guard loadState != .unreadable else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == id }),
              accounts[index].name != trimmed else {
            return
        }

        let snapshot = snapshot()
        accounts[index].name = trimmed
        _ = persistOrQuarantine(restoring: snapshot)
    }

    public func reorder(_ orderedIDs: [AccountID]) {
        resolveLoadIfNeeded()
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

        let snapshot = snapshot()
        accounts = reordered
        _ = persistOrQuarantine(restoring: snapshot)
    }

    public func recordProviderIdentity(
        _ identity: ProviderAccountIdentity,
        for id: AccountID
    ) {
        resolveLoadIfNeeded()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        guard accounts[index].providerIdentity != identity else { return }

        if loadState == .unreadable {
            accounts[index].providerIdentity = identity
            return
        }

        let snapshot = snapshot()
        accounts[index].providerIdentity = identity
        _ = persistOrQuarantine(restoring: snapshot)
    }

    public func markConnected(_ id: AccountID, revision: CredentialRevision) {
        resolveLoadIfNeeded()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }

        if loadState == .unreadable {
            accounts[index].authorizationState = .connected
            lineage[id] = revision
            return
        }

        let snapshot = snapshot()
        accounts[index].authorizationState = .connected
        lineage[id] = revision
        _ = persistOrQuarantine(restoring: snapshot)
    }

    public func markNeedsReauthentication(_ id: AccountID, failedRevision: CredentialRevision?) {
        resolveLoadIfNeeded()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }

        if let failedRevision,
           let currentRevision = lineage[id],
           currentRevision != failedRevision {
            return
        }

        if loadState == .unreadable {
            accounts[index].authorizationState = .needsReauthentication(
                failedRevision: failedRevision
            )
            return
        }

        let snapshot = snapshot()
        accounts[index].authorizationState = .needsReauthentication(
            failedRevision: failedRevision
        )
        _ = persistOrQuarantine(restoring: snapshot)
    }

    /// This catalog holds no durable store, so every scheduled commit is already complete.
    public func drainPendingCommits() async {}

    private func resolveLoadIfNeeded() {
        if loadState == .loading { load() }
    }

    private func persistOrQuarantine(restoring snapshot: Snapshot) -> Bool {
        switch persistOutcome {
        case .succeeds:
            if snapshot.loadState == .missing { loadState = .loaded }
            return true
        case .failsCatalogUnreadable:
            restore(snapshot)
            loadState = .unreadable
            return false
        }
    }

    private func restore(_ snapshot: Snapshot) {
        accounts = snapshot.accounts
        reservations = snapshot.reservations
        pendingReservationCount = snapshot.pendingReservationCount
        lineage = snapshot.lineage
        recoveryAdvisory = snapshot.recoveryAdvisory
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            accounts: accounts,
            pendingReservationCount: pendingReservationCount,
            loadState: loadState,
            recoveryAdvisory: recoveryAdvisory,
            reservations: reservations,
            lineage: lineage
        )
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

    private nonisolated struct Reservation: Sendable {
        let name: String
        let provider: AccountProvider
        let reference: CredentialReference
    }

    private nonisolated struct Snapshot: Sendable {
        let accounts: [AccountConfig]
        let pendingReservationCount: Int
        let loadState: CatalogLoadState
        let recoveryAdvisory: CatalogRecoveryAdvisory?
        let reservations: [AccountID: Reservation]
        let lineage: [AccountID: CredentialRevision]
    }
}
