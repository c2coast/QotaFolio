import Observation

// The vault's reporting seam, and ONLY the vault's. Both members are `async` because a report
// is not finished until the catalog change it describes is durable on the device. The vault awaits
// them, so a refresh flight stays in `activeRefreshTasks` until its commit lands — which is what makes
// the vault's existing quiescence drain, the one quit and uninstall already await, cover the commit
// too. No separate shutdown hook is needed for the automatic path.
//
// `AccountCataloging` does not inherit this protocol.
// The UI-facing `markConnected` is a synchronous optimistic mutation and must stay synchronous for its
// MainActor callers; the vault's report must be async. One type implements both, so they cannot share a
// name — a sync/async overload pair differing only in `async` is an overload-resolution trap. Hence
// `record…` here and `mark…` on `AccountCataloging`.
@MainActor public protocol AccountAuthorizationStateSink: AnyObject, Sendable {
  func recordConnected(_ id: AccountID, revision: CredentialRevision) async
  func recordNeedsReauthentication(_ id: AccountID, failedRevision: CredentialRevision?) async }

@MainActor public protocol AccountCataloging: AnyObject, Sendable, Observable {
  var accounts: [AccountConfig] { get }             // ordered by displayOrder. Pending-add reservations do NOT appear here
  var pendingReservationCount: Int { get }          // reservations count toward the ≤5 cap and the "N of 5" header via THIS, so no ghost row renders mid-add and the strip never sees a snapshot-less account
  var loadState: CatalogLoadState { get }
  // True when the last read DID NOT HAPPEN, so reading again is meaningful. `.unreadable` is one
  // word for three situations and only this one may be retried: corrupt bytes read again are the
  // same corrupt bytes, and a failed commit left a repair in memory that a re-read would destroy.
  // Without this question the panel could only offer quit, reopen, reinstall — for a descriptor
  // shortage that the next glance would have survived.
  // `load()` IS the retry: it is idempotent, it re-reads exactly in this state, and it is a no-op
  // in every other, so a surface may call it whenever it wants the catalog to reflect the device.
  var loadCanBeRetried: Bool { get }
  var recoveryAdvisory: CatalogRecoveryAdvisory? { get }   // see CatalogRecoveryAdvisory below
  func load()
  func setRecoveryAdvisory(_ advisory: CatalogRecoveryAdvisory?)   // composition root ONLY, after the startup vault-enumeration check
  // ADD is two-phase: reserve (counts toward the ≤5 cap) → coordinator runs performStore → finalize or release.
  func reserveAddSlot(name: String, provider: AccountProvider) throws -> AccountID   // throws AccountCatalogError
  func finalizeAdd(_ pendingID: AccountID, revision: CredentialRevision) throws      // durable finalization throws .catalogUnreadable
  func releaseReservation(_ pendingID: AccountID)   // synchronous, nonthrowing, idempotent cleanup; NOT `remove` (which is for real rows)
  // Only `releaseReservation` is nonthrowing; reserveAddSlot and finalizeAdd remain throwing.
  // Release is legal in .loading/.missing/.loaded/.unreadable and touches ONLY memory-resident reservation bookkeeping:
  // remove `pendingID` if and only if it exists, so `pendingReservationCount` decreases by one exactly in that case. An
  // unknown or already-released ID is an exact no-op. Release never reads, encodes, writes or otherwise touches durable
  // catalog bytes, and leaves `loadState`, `accounts` and the catalog file unchanged. This is why cancellation/failure/quit
  // cleanup always executes and has no `try?` or cleanup-error branch.
  // `finalizeAdd` is different: it is the durable catalog mutation after performStore has committed the credential, so a
  // persistence failure still flips the catalog to .unreadable and throws `AccountCatalogError.catalogUnreadable`; the
  // coordinator maps that throw → `AccountFlowFailure.storeFailed`, releases the memory-only reservation nonthrowingly,
  // and the unreferenced envelope is reclaimed on the next `.loaded` launch rather than reported as an advisory.
  // NOTE EXACTLY WHICH FAILURE THAT THROW CARRIES. `finalizeAdd` throws when the catalog is ALREADY .unreadable, which
  // is the case it could always answer synchronously. It cannot throw for the commit it just scheduled, because that
  // commit's outcome arrives after two device flushes and this call must not block the main thread waiting for them.
  // A commit that fails afterwards rolls the row back and flips .loadState to .unreadable, which the panel renders as
  // the account-list-unavailable takeover, so the failure reaches the user — one commit round trip later, through the
  // catalog's own state rather than through this throw.
  func remove(_ id: AccountID); func rename(_ id: AccountID, to name: String); func reorder(_ orderedIDs: [AccountID])
  // The optimistic authorization mutations. Both apply the change to memory and schedule the
  // durable commit; neither performs it.
  func markConnected(_ id: AccountID, revision: CredentialRevision)
  func markNeedsReauthentication(_ id: AccountID, failedRevision: CredentialRevision?)
  // Which provider account a row's grant belongs to, once the provider has answered for it. This
  // is what makes `ProviderIdentityEnrollment` able to say "you already added this account": a row
  // with no identity cannot take part in that check, and every row written before the app learned
  // to ask starts without one.
  func recordProviderIdentity(_ identity: ProviderAccountIdentity, for id: AccountID)
  // Every catalog mutation is optimistic in memory and durable later, because a durable commit
  // is two `F_FULLFSYNC` device flushes and this protocol is @MainActor. This waits for the durable
  // outcome of every commit scheduled BEFORE the call. It never waits on a commit scheduled after it,
  // so it cannot chase a moving queue and cannot be starved by ongoing edits.
  // The shutdown path owns this: quit and uninstall call it so a commit in progress at termination is
  // completed rather than dropped. A conformer with no durable store implements it as a no-op.
  func drainPendingCommits() async }

public nonisolated enum AccountCatalogError: Error, Sendable {
  case accountLimitReached(maximum: Int)   // maximum == qotaFolioMaximumAccounts, counting live rows + pending reservations
  case catalogUnreadable }

public nonisolated enum CatalogLoadState: Equatable, Sendable { case loading; case missing; case loaded; case unreadable }

public nonisolated enum CatalogRecoveryAdvisory: Equatable, Sendable {
  case credentialsWithoutCatalog(count: Int)   // the store ANSWERED: N credentials survive a broken catalog — "do not re-authorize"
  // The catalog is untrustworthy AND the credential store could not be read. A SEPARATE CASE, not `count: Int?` —
  // these are different FACTS with different user instructions ("N survive" vs "we could not check; do NOT assume they are
  // gone"), an optional count forces the panel to branch inside the case anyway, AND it lets a builder render the survivors-copy with
  // a blank number: false reassurance with extra steps. Copy owned by the panel; NEVER a deletion, NEVER auto-repair.
  case credentialStoreUnreachable
  // The read NEVER HAPPENED — a descriptor shortage, a momentarily unusable anchor. NOTHING was
  // learned about the catalog, so nothing about it may be reported and no claim about the saved
  // sign-ins may rest on it. A SEPARATE CASE from the two above, and it OUTRANKS them while it
  // holds: `credentialsWithoutCatalog(count:)` is computed by subtracting the catalog's own rows
  // from the store's, so a catalog that was never read makes every surviving sign-in look like an
  // orphan. That count is not a fact here, and the copy that carries it tells the user to quit and
  // reopen an app that would have recovered by itself. This case says the one true thing —
  // we could not read it just now — and the surface that renders it offers the retry.
  case catalogTemporarilyUnreadable }

/// The advisory a recovery surface presents, which is not always the one the composition root
/// published.
///
/// The root publishes what it learned about the CREDENTIAL STORE, after the startup enumeration.
/// It sees `loadState == .unreadable` and cannot see which of the three unreadable situations it
/// is, because nothing in `CatalogLoadState` says. When the read never happened, the published
/// advisory is an inference drawn from rows nobody read, so it is withdrawn here and replaced by
/// the fact that is true: the list could not be read just now. In every other state the published
/// advisory stands unchanged.
public nonisolated func presentedCatalogRecoveryAdvisory(
  published: CatalogRecoveryAdvisory?,
  loadState: CatalogLoadState,
  loadCanBeRetried: Bool
) -> CatalogRecoveryAdvisory? {
  guard loadState == .unreadable, loadCanBeRetried else { return published }
  return .catalogTemporarilyUnreadable }
