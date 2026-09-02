public nonisolated enum TokenVaultError: Error, Sendable {
  case credentialStoreInProgress                                  // a performStore attempt is already active for this account. UNREACHABLE from poller paths — the poller only calls getValidToken/refreshAfterUnauthorized, which never contend for the store slot. Poller: Debug assert + treat as .stale(.temporarilyUnavailable); never a suspend.
  case temporarilyUnavailable                                     // TRANSIENT refresh/network failure (token-endpoint 5xx / timeout / drop) — preserve credential, retry; poller → .stale(.temporarilyUnavailable)
  case storageTemporarilyUnavailable                              // Keychain locked / interactionNotAllowed / entitlement — "could not read NOW" ≠ absent; never delete, never mark reauth; poller → .stale(.storageTemporarilyUnavailable)
  case credentialUnavailable                                      // no credential for this account (missing or removed). The poller writes .configurationFailure and stops the account, never .stale: retrying cannot bring a credential back, and there is no rejected lineage to reauthenticate against. Writing no phase at all would leave the row on the one it had — plausibly .current with a last-good snapshot — so a number would go on reading as current for an account whose credential is gone.
  case credentialCorrupt                                          // Keychain blob unreadable / unknown envelope schema — explicit failure, never treated as absent; poller → .stale(.credentialUnreadable), distinct from configurationFailure
  case providerMismatch                                           // token-set / acquirer / stored provider disagree. Poller → .configurationFailure (a genuine PERSISTENT misconfiguration — the stored provider and the injected provider code disagree; retrying cannot fix it, and it is NOT a credential-lifetime problem, so never .stale and never a reauth suspend)
  case accountRemoved                                             // the account was deleted during the operation (lifecycle generation advanced). The poller DROPS THE DELIVERY — identical handling to a generation mismatch. The account is gone: write NO status (a status write would resurrect a row's entry), cancel the attempt, discard.
  case reauthenticationRequired(failedRevision: CredentialRevision?) }

public nonisolated enum CredentialStorePurpose: Sendable { case add; case reauthenticate }

public nonisolated struct CredentialStoreRequest: Sendable { public let accountID: AccountID; public let provider: AccountProvider; public let purpose: CredentialStorePurpose
  public init(accountID: AccountID, provider: AccountProvider, purpose: CredentialStorePurpose) { self.accountID = accountID; self.provider = provider; self.purpose = purpose } }

public nonisolated struct CredentialStoreReceipt: Sendable { public let accountID: AccountID; public let provider: AccountProvider; public let revision: CredentialRevision
  public init(accountID: AccountID, provider: AccountProvider, revision: CredentialRevision) { self.accountID = accountID; self.provider = provider; self.revision = revision } }

public nonisolated enum OAuthLoginError: Error, Sendable {   // login-side failures; the coordinator maps 1:1 → AccountFlowFailure (except .storeFailed, which is the vault's commit half)
  case browserOpenFailed        // ANTHROPIC-ONLY — thrown when the authorize browser cannot open; the listener is stopped first, so the transaction is dead and the only affordance is retryActiveFlow(). A ChatGPT builder must NEVER throw this: the device flow needs no local browser — a failed open leaves .openAIAwaitingDevice LIVE and the panel offers copy-URL from the phase payload.
  case startFailed(DeviceCodeStartFailure)   // flow couldn't BEGIN. The typed payload is what lets the panel render specific copy:
                                             //   .rateLimited  → /deviceauth/usercode 429 ⇒ serialize + back off; "Too many attempts, try shortly"
                                             //   .unavailable  → device-code sign-in disabled by the user's ChatGPT security settings or a workspace admin ⇒ an Enterprise
                                             //                   user may be UNABLE to add a ChatGPT account at all; say so specifically, never a mystery error
                                             //   .transport    → network/transport failure at start ⇒ plain "Try again"
  case deadlineExpired; case denied; case listenerUnavailable; case exchangeFailed
  case scopeNotGranted          // the grant came back short of the ONE permission this app asks for, so it can never read a number. Terminal and distinct from .exchangeFailed: retrying the same sign-in reproduces it, and the user has to approve the permission instead.
}

public nonisolated enum DeviceCodeStartFailure: Equatable, Sendable {
  // `retryAt` is the ABSOLUTE monotonic instant the provider said the caller may try again, or nil when the 429 carried no
  // Retry-After. The client that read the 429 computes it ONCE, from the header and the clock reading it already holds, and
  // every consumer carries it unchanged. Nothing downstream recomputes it and nothing needs an arrival anchor to interpret it.
  //
  // It is deliberately not a Duration. A relative delay is only meaningful together with the instant it was measured from, so
  // a Duration payload forces every consumer to keep that anchor itself — and two rate limits that differ only in WHEN they
  // arrived are then byte-identical, which no consumer can undo. An instant carries its own meaning and makes them distinct.
  case rateLimited(retryAt: ContinuousClock.Instant?)
  case unavailable
  case transport }

public nonisolated protocol OAuthTokenAcquirer: Sendable {
  var provider: AccountProvider { get }
  func acquireTokens(report: @MainActor @Sendable @escaping (AccountFlowPhase) -> Void) async throws -> OAuthTokenSet }

public nonisolated protocol TokenVault: Sendable {   // nonisolated deliberately: every sibling protocol is — without it the MainActor-default project infers @MainActor and forbids an `actor` vault, pinning Keychain and the refresh POST to the main thread.
  func performStore(_ request: CredentialStoreRequest, using acquirer: any OAuthTokenAcquirer, report: @MainActor @Sendable @escaping (AccountFlowPhase) -> Void) async throws -> CredentialStoreReceipt
    // `report:` ISOLATION, COMPILE- AND RUNTIME-PROVEN; the SAME attribute is on OAuthTokenAcquirer.acquireTokens above:
    //   the bare `@Sendable @escaping` form CANNOT drive the coordinator's @MainActor state — assigning `activeFlow` inside it is
    //   "error: main actor-isolated property 'activeFlow' can not be mutated from a Sendable closure". That left exactly two forms,
    //   both wrong: `MainActor.assumeIsolated` COMPILES and then TRAPS at runtime (SIGTRAP/133) when `report` fires from the vault
    //   actor — which this contract MANDATES (".storing before commit") — and `Task { @MainActor in … }` costs one hop per phase with
    //   NO ordering guarantee across hops. `@MainActor` on the closure type
    //   removes all three problems at zero cost: every caller (acquireTokens, the vault's .storing emission) is already `async`, so
    //   `await report(...)` is ordered and synchronous-on-arrival, and the coordinator assigns `activeFlow` DIRECTLY — no Task, no assumeIsolated.
    // Rejects a same-account active attempt with .credentialStoreInProgress. Records a fresh private attempt-id + lifecycle generation,
    // forwards `report` to acquireTokens, then checks Task cancellation immediately after acquireTokens returns; emits `.storing` through
    // the awaited MainActor report hop, then checks cancellation again; rechecks attempt/generation/provider/purpose; then enters ONE
    // synchronous atomic commit segment with no suspension point. Cancellation before that final checkpoint writes nothing; cancellation
    // after the segment has begun may let the already-started atomic commit finish.
    // EVERY exit path (cancel/denial/timeout/browser-fail/poll-fail/exchange-fail/store-fail) releases via one scoped defer — CLEARING ONLY IF the
    // slot still holds THIS attempt-id (identity-scoped, symmetric with the refresh flight's clear-if-current-flight-id; an unconditional clear
    // would erase a newer attempt admitted after a delete→re-add). Commit invalidates any in-flight refresh via revision.
  func getValidToken(accountID: AccountID) async throws -> ValidAccessToken
  func refreshAfterUnauthorized(accountID: AccountID, rejectedRevision: CredentialRevision) async throws -> ValidAccessToken
  func deleteTokens(for accountID: AccountID) async throws }

public nonisolated struct CredentialReconcileRecord: Sendable, Equatable {
  public let reference: CredentialReference
  public let accountID: AccountID
  public let provider: AccountProvider
  public let failedRevision: CredentialRevision?
  public init(reference: CredentialReference, accountID: AccountID, provider: AccountProvider, failedRevision: CredentialRevision?) {
    self.reference = reference; self.accountID = accountID; self.provider = provider; self.failedRevision = failedRevision } }

public nonisolated enum StoredCredentialScan: Equatable, Sendable {
  case enumerated(Set<CredentialReference>)
  case unavailable }

// ── THE SAME RULE, ONE LEVEL UP: A PASS THAT COULD NOT FINISH IS NOT THE FACT "THERE WAS NOTHING TO REPAIR".
// `StoredCredentialScan` above forbids the collapse for ONE enumeration. `reconcile(_:)` is a whole pass — an enumeration,
// a read per referenced account, then the deletions and the sink calls those reads justify — and a bare
// `[AccountID: CredentialRevision]` would let an empty map mean BOTH "I finished and there was nothing to repair" AND "I stopped
// because the store would not answer". The root gates on its OWN scan, which closes every shape it can see, and one shape
// stays invisible to it: a pass that aborts on a READ while enumeration still works and leaves no orphan behind — the
// locked-Keychain-with-a-tidy-store case, where the user would be told everything was fine while nothing had been checked.
//
// WHY AN ENUM AND NOT `[AccountID: CredentialRevision]?`: the Optional forces an unwrap and then **`?? [:]` restores the
// exact collapse in ONE innocuous token**, which is the argument that decided `StoredCredentialScan` and decides this.
// MEASURED on this enum, by compiling each mistake: `?? [:]` is EXIT=1 ("binary operator '??' cannot be applied
// to operands of type 'CredentialReconcileOutcome' and '[AnyHashable : Any]'"), a consumer that handles `.completed` and
// not `.aborted` is EXIT=1 ("switch must be exhaustive"), reading the pre-repair map straight out of the call is EXIT=1
// ("cannot convert return expression of type 'CredentialReconcileOutcome' to return type '[AccountID : CredentialRevision]'"),
// `.isEmpty` on the result is EXIT=1 ("value of type 'CredentialReconcileOutcome' has no member 'isEmpty'"), and `.aborted`
// cannot be spelled without naming the refusal observed ("missing argument for parameter #1 in call"; and in prose instead
// of a case, "cannot convert value of type 'String' to expected argument type 'CredentialStoreObstruction'"). The mistake is
// UNWRITABLE, not merely discouraged. [RUN] locked store + tidy store ⇒ `.aborted(.itemReadRefused, [:])` · the same store
// reading ⇒ `.completed([:])` · a stale row over a live credential ⇒ `.completed([id: revision])` — and the root
// publishes `.credentialStoreUnreachable` for the first.
//
// There is deliberately NO `var reauthenticated` accessor on the outcome. It would hand back the map without the verdict
// attached, which is `?? [:]` wearing a property name — the one token that undoes everything this type is for. MEASURED:
// `outcome.reauthenticated` is EXIT=1 ("value of type 'CredentialReconcileOutcome' has no member 'reauthenticated'").

/// What the credential store refused to do, when a reconciliation pass stopped early.
///
/// Every case is a statement about the STORE and about one operation on it. None of them is ever a statement about a
/// credential: an obstruction never means a credential is absent, wrong or gone, and no caller may act as if it did.
/// The three cases are three different amounts of ignorance, and a pass must say which one it is in.
public nonisolated enum CredentialStoreObstruction: Equatable, Sendable {
  case enumerationRefused   // the store would not list what it holds, so NOTHING is known to be unreferenced and nothing may be deleted
  case itemReadRefused      // it listed, then would not hand back one referenced item's data. THE LOCKED-KEYCHAIN SHAPE: attributes still answer, item data does not. "Could not read NOW" ≠ absent (see `TokenVaultError.storageTemporarilyUnavailable`), so no account may be marked as needing re-authorization from it.
  case itemDeleteRefused }  // every read answered and the store then would not remove a credential the catalog does not reference. The CHECK finished; the REPAIR did not, and an unreferenced credential is still on the device.

/// What one reconciliation pass did, and whether it finished.
///
/// `reauthenticated` carries the same thing in both cases: exactly the revisions whose startup `.markConnected` sink call
/// COMPLETED in this pass, which — because that call is awaited to its durable commit — means the catalog change for each
/// one is already on the device. Orphan deletion and `.markNeedsReauthentication` repairs stay internal and never enter it.
/// It is on `.aborted` too, and not only on `.completed`, because an abort rolls nothing back: a pass that stopped after a
/// repair landed durably still landed it, and dropping it here would leave the polling store disagreeing with a catalog row
/// that is already written. The two read refusals answer before any action is computed, so they always carry an empty map;
/// `.itemDeleteRefused` is the case that can carry a non-empty one, and it must not be modelled as if it could not.
public nonisolated enum CredentialReconcileOutcome: Equatable, Sendable {
  case completed(reauthenticated: [AccountID: CredentialRevision])
  case aborted(CredentialStoreObstruction, reauthenticated: [AccountID: CredentialRevision]) }

public nonisolated protocol TokenVaultMaintenance: Sendable {
  // ── A FAILURE TO ENUMERATE IS NOT THE FACT "NOTHING IS UNREFERENCED", AND THIS TYPE REFUSES TO CONFLATE THEM.
  // The `.missing`/`.unreadable` advisory promises the user *"your catalog is broken, but your credentials survive — do not
  // re-authorize"*. That promise is only makeable if the vault was actually READ. When enumeration fails, publishing NOTHING
  // tells the user "nothing to worry about" — the false-reassurance mode this whole area exists to prevent, and the same shape
  // as the "never a 0% bar implying spare capacity" rule. Silence is the one disposition that is definitely wrong.
  // WHY AN ENUM AND NOT `Set?` — and this is the deciding argument: an Optional forces an unwrap, but
  // **`?? []` restores the exact collapse in ONE innocuous token**. MEASURED on the enum: `?? []` is EXIT=1 (*"binary operator
  // '??' cannot be applied to operands of type 'StoredCredentialScan' and '[Any]'"*), treating the scan as a set is EXIT=1
  // (*"has no member 'subtracting'"*), and a consumer that ignores the new advisory case is EXIT=1 (*"switch must be
  // exhaustive"*). The mistake is UNWRITABLE, not merely discouraged. [RUN] `.missing` + failure ⇒ `.credentialStoreUnreachable`
  // · `.missing` + 3 found ⇒ `.credentialsWithoutCatalog(count: 3)` · `.missing` + 0 found ⇒ `nil` — THREE distinct outcomes,
  // and silence survives in the one place it is true.
  // `.loaded` is necessary but not sufficient. The root may call `reconcile(_:)` if and only if its own
  // `scanStoredCredentials()` result is `.enumerated(_)`; `.loaded + .unavailable` makes no reconcile call and performs no
  // deletion this launch. `reconcile`'s internal availability abort is not a substitute for this root gate: a hypothetical
  // second enumeration can recover after the failed root scan, which is the two-phase mistake this root gate exists to make impossible.
  func scanStoredCredentials() async -> StoredCredentialScan           // A read-only enumeration, honest about its own failure. References only, never secrets.
  // Report what this pass DID and whether it FINISHED — see `CredentialReconcileOutcome` above.
  // Fail-closed is stated by the type: a refusal from the store on the enumeration or on any
  // referenced read returns `.aborted(_, reauthenticated: [:])` BEFORE a single action is computed, so no deletion and no
  // `.markNeedsReauthentication` can ever rest on a partial read. The root publishes `.credentialStoreUnreachable` for
  // every `.aborted`, and silence only for `.completed`.
  func reconcile(
    _ records: [CredentialReconcileRecord]
  ) async -> CredentialReconcileOutcome }

/// Ends one grant at the provider that issued it.
///
/// The vault owns this, because the vault is the only thing that holds the refresh token and the
/// secret has no business leaving it. There is no result: a disconnect removes the credential
/// from this Mac whatever the network answers, so no caller may make the local wipe conditional
/// on a call that can fail.
///
/// The rule this app keeps is **never revoke a credential it did not mint** — not "never revoke".
/// Every credential the vault holds came from QotaFolio's own PKCE flow, and the app reads no
/// other application's credential store, so there is nothing else here to reach.
public nonisolated protocol GrantRevoking: Sendable {
  var provider: AccountProvider { get }
  func revoke(refreshToken: SecretString) async }
