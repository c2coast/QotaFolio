import Foundation
import Observation

public nonisolated enum AccountFlowFailure: Equatable, Sendable {   // Every OAuthLoginError case appears here, mapped one for one by the coordinator, plus the failures only the store and the flow itself can produce. `.cancelled` is one of the second group: it arrives from a `CancellationError` inside `performStore`, never from the login half.
  case browserOpenFailed          // Anthropic only. ChatGPT's device flow needs no local browser, so a failed open there leaves .openAIAwaitingDevice live and the user copies the URL instead. Here the listener is already stopped and the transaction is dead, so a fresh sign-in through retryActiveFlow() is the only affordance.
  case startFailed(DeviceCodeStartFailure)   // The payload is CARRIED across the mapping rather than dropped. A bare case leaves the panel
                                             // unable to tell "429, try shortly" from "your admin disabled device-code sign-in, you cannot
                                             // add this account", so both would arrive at the user as one generic "Try again".
  case deadlineExpired            // Anthropic ~10m transaction / OpenAI 15m device code — offer "Get a new code" / "Try again"
  case denied                     // provider auth denial (terminal, no exchange)
  case listenerUnavailable        // the loopback listener could not bind — a port already taken, or the sandbox refusing network.server
  case exchangeFailed             // token exchange rejected (single-use, no auto-retry)
  case scopeNotGranted            // the provider signed the user in but withheld the permission that reads usage. Distinct from .exchangeFailed on purpose: "try again" is the wrong instruction — the same flow grants the same nothing until the permission is approved.
  case storeFailed                // Keychain commit failed (the write itself was attempted and rejected/aborted) — copy: "Couldn't save the credential"
  // The sign-in worked and the provider says this grant belongs to an account QotaFolio already
  // holds. The browser grants whichever account it is already signed in to, so this is what a
  // second add looks like when the user is signed in to the first one — two rows, identical bars,
  // and nothing said. The colliding account's NAME is carried because the sentence the user reads
  // names it: "the same account as Work" is an answer, "duplicate account" is a code. Terminal,
  // and "try again" is the wrong instruction — the same sign-in grants the same account.
  case alreadyConnected(accountName: String)
  case storageUnavailable         // Keychain LOCKED / interactionNotAllowed / entitlement — "could not write NOW" ≠ "the write failed". USER-ACTIONABLE and deliberately DISTINCT from .storeFailed: the copy is "unlock your Keychain and try again", and collapsing it into .storeFailed would destroy the contract's own "'could not read NOW' ≠ absent" distinction (TokenVaultError.storageTemporarilyUnavailable) on the write side
  case cancelled }

public nonisolated enum AccountFlowPhase: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {   // The UI-facing projection of a sign-in, symmetric with AccountPollStatus. The coordinator owns the machine and the panel only switches on it; the acquirer emits the mid-flow subset (WaitingInBrowser/AwaitingDevice/exchanging) through `report`.
  case naming                                                                          // entering the display name (pre-auth, .add)
  case starting                                                                        // flow starting — slot reserved (.add only; reauth reserves none), acquirer being built. Both add and reauth pass through here.
  case anthropicWaitingInBrowser(authorizationURL: URL)   // The URL is CARRIED, not merely described in prose: `reopenAuthorizationBrowser()` has no other source for one. It re-opens the SAME live URL — same state, same PKCE, same port — and never starts a new flow.
  case openAIAwaitingDevice(userCode: String, verificationURL: URL, expiresAt: Date)   // device code shown; polling
  case exchanging                                                                      // callback/code received; exchanging
  case storing                                                                         // performStore committing
  case connected                                                                       // **TRANSIENT — this phase NEVER persists in `activeFlow`.** After this attempt's channel is finished and drained, the coordinator checks `channel.id == attempt` once more, then finalizes in one synchronous no-suspension segment: catalog append/markConnected → set pendingConnectedAnnouncement → `activeFlow = nil`. `.connected` may be emitted through `report:` as a momentary phase and may be observed for the length of one render, but it is never a state a dismissal has to clear. **The ROW + the announcement are the success signal**, so there is no separate result carrier for a surface to read. Consequences: the Escape table's second arm is `.failed`-only, the hide edge's "clears a TERMINAL .failed" is COMPLETE, and a flow that completes while the panel is hidden leaves `activeFlow == nil` with the announcement pending — so an add-flow view never outranks the account list when the panel is opened next.
  case failed(AccountFlowFailure)
  // Without all three conformances — on the one enum deliberately made to CARRY the live authorize URL — interpolation,
  // String(describing:), String(reflecting:) and dump() print `state` + `code_challenge` IN FULL. `state` is the live CSRF token of an
  // IN-FLIGHT loopback transaction: the listener's exact-callback validation depends on its secrecy for the transaction's lifetime, and a
  // callback URL is the last thing that may reach a log. This enum is `@Observable`-adjacent (the value of AddFlowPresenting.activeFlow), crosses two
  // isolation domains via `report:`, and is a natural thing to interpolate into a diagnostic — so it needs all three conformances, not one.
  // The rendering rule: **CASE NAME ONLY**, with exactly two allowances — the authorize URL's HOST (never path, NEVER query items) and the
  // device `userCode`, the sole credential-adjacent value this product displays on purpose. `.failed`'s payload is deliberately NOT rendered.
  public var description: String {
    switch self {
    case .naming: "naming"
    case .starting: "starting"
    case .anthropicWaitingInBrowser(let url): "anthropicWaitingInBrowser(host: \(url.host() ?? "?"))"
    case .openAIAwaitingDevice(let userCode, _, _): "openAIAwaitingDevice(userCode: \(userCode))"
    case .exchanging: "exchanging"
    case .storing: "storing"
    case .connected: "connected"
    case .failed: "failed"
    } }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: []) } }

/// Why an account was not removed. One case per distinct answer `removeAccount` gives.
///
/// Removal is refused on a gate the panel cannot observe: a quit that has already closed account
/// changes leaves the Remove button looking live while the removal goes nowhere. This case is that
/// interval made sayable.
public nonisolated enum AccountRemovalRefusal: Equatable, Sendable {
  case accountChangesAreClosed  // the app is quitting and holds account changes closed until the process exits
  case accountListUnreadable      // the account list could not be read, so nothing may be removed from it
  case accountAlreadyRemoved      // the account is not in the list any more
  case removalWasNotApplied       // the list was asked and the account is still there
}

/// Why reconnecting did not start. One case per guard `beginReauth` returns on.
///
/// Reconnect is the affordance a user reaches only after their account has already stopped
/// working, so a press that does nothing confirms the fear that brought them there.
///
/// The sentences lead with the press rather than with the cause, because the press is what the
/// user is asking about and because a cause can stop being true while the sentence is on screen.
public nonisolated enum AccountReconnectRefusal: Equatable, Sendable {
  case accountChangesAreClosed  // the app is quitting and holds account changes closed until the process exits
  case anotherAccountFlowIsOpen  // a sign-in is already running, and one flow at a time is the rule
  case accountListUnreadable     // the account list could not be read, so the account to reconnect could not be found in it
  case accountIsNoLongerListed   // the list was read and this account is not in it
}

/// Why the add flow is back on its naming step after a Continue that could not start a flow.
///
/// Every case here means the same thing to the user: the step is still on screen, what they
/// entered is still in it, and this sentence says why.
public nonisolated enum AddFlowRefusal: Equatable, Sendable {
  case accountLimitReached       // five accounts already; the sixth cannot be reserved
  case accountChangesAreClosed  // the app is quitting and holds account changes closed; nothing was started
  case accountListUnreadable     // the account list could not be read, so no slot could be reserved in it
  case accountCouldNotBeReserved // the list refused the slot for a reason with no better name
}

public nonisolated enum FlowDismissalReason: Equatable, Sendable { case userCancel; case escape; case quit }

@MainActor public protocol AddFlowPresenting: AnyObject, Observable {
  var activeFlow: AccountFlowPhase? { get }              // nil = no flow; the panel renders a projection and NEVER owns flow state
  var activeFlowProvider: AccountProvider? { get }       // set for the flow's whole lifetime INCLUDING terminal .failed — without it `.deadlineExpired`'s affordance copy and the per-provider retry identifiers are underivable from any declared surface
  var pendingConnectedAnnouncement: AccountID? { get }   // set on EVERY receipt (the finalize order is unconditional — it does not consult visibility); consumed on one of the two triggers below, so it is pending only for as long as it takes the nearer one to fire
  func consumeConnectedAnnouncement() -> AccountID?      // The announcement's DECLARED CONSUMER — returns the pending ID and CLEARS it ATOMICALLY (one @MainActor call; a read-then-clear pair would race the panel's own read on the same edge). The property above stays for the panel's rendering and observation; THIS is the only clearer. Idempotent: a second call on the same trigger returns nil.
    // ── **TWO CONSUMER TRIGGERS, NOT ONE.** The panel calls `consumeConnectedAnnouncement()` and announces a non-nil result:
    //   (1) on each **hidden→visible** transition, AND
    //   (2) whenever `pendingConnectedAnnouncement` **goes non-nil WHILE THE PANEL IS ALREADY VISIBLE**.
    // **ONE announcement per add, never zero, never stale.** The producer is unconditional (the finalize order runs on every receipt with no
    // visibility check), so a single hidden→visible consumer covers only one of the producer's two cases. The other is the COMMON one — the
    // user completes an add with the panel OPEN, and there is no hidden→visible edge coming. Without trigger (2) that add would complete
    // SILENTLY for a VoiceOver user, and the ID would stay non-nil until the NEXT hide→show — at which point the panel would announce
    // "account connected" for an account connected minutes or hours earlier.
    // Trigger (2) is an ordinary `@Observable` reaction on a property the panel already observes — no new machinery, no timer, no new seam. The two
    // triggers cannot double-fire: the consume is atomic and idempotent, so whichever fires first returns the ID and the other returns nil.
  var addFlowRefusal: AddFlowRefusal? { get }             // why the naming step is back on screen after a Continue that could not start a flow. nil for every ordinary step.
  func beginAddFlow()
  // Continue answers, for the reason `removeAccount` and `beginReauth` do.
  // `addFlowRefusal` is the OBSERVABLE the naming step renders its caption from, and it
  // outlives the press. This is the ANSWER TO THIS PRESS, and only an answer can be announced. A
  // press that reads the observable back instead announces whatever is there — including a refusal
  // an earlier press left, on a path that returns before the observable is cleared. That is the
  // "never stale" half of this app's one-announcement-per-action rule, broken by construction.
  // Deliberately NOT `@discardableResult`: under warnings-as-errors a caller that drops the answer
  // does not compile, so a further guard cannot be added without a case, and a case cannot be added
  // without a sentence for the user to read.
  func submitAdd(name: String, provider: AccountProvider) -> AddFlowRefusal?
  // The reconnect answers. Deliberately NOT `@discardableResult`, for the
  // reason `removeAccount` is not: under warnings-as-errors a caller that drops the answer does
  // not compile, so a further guard cannot be added without a case, and a case cannot be added
  // without a sentence for the user to read.
  func beginReauth(_ id: AccountID) -> AccountReconnectRefusal?
  func cancelActiveFlow(_ reason: FlowDismissalReason)
  func acknowledgeFailure()                               // clears a TERMINAL .failed flow without cancelling anything live
  func retryActiveFlow()                                  // generic retry for a terminal failure — starts a FRESH flow; also the ONLY affordance for .browserOpenFailed (on that path the listener and the transaction are already dead, so "Open browser again" is impossible)
  func requestNewDeviceCode()                             // OpenAI: user asked for a fresh code. Gated by DeviceCodeStartFailure.rateLimited(retryAt:) — the panel disables the retry affordance until that instant when the provider named one; the coordinator NEVER auto-retries. Both halves of the gate read the SAME instant off the failure, so the panel and the coordinator cannot disagree about when the gate opens.
  func reopenAuthorizationBrowser()                       // Anthropic: "Open browser again" — re-opens the SAME live authorize URL (same state/PKCE/port); it does NOT start a new flow; valid ONLY in .anthropicWaitingInBrowser
  // The removal answers. Deliberately NOT `@discardableResult`: under warnings-as-errors a caller that drops
  // the answer does not compile, so a further guard cannot be added without a case, and a case
  // cannot be added without a sentence for the user to read.
  func removeAccount(_ id: AccountID) -> AccountRemovalRefusal? }

@MainActor public protocol EscapeInterceptable: AnyObject { var escapeHandler: (() -> Bool)? { get set } }

public typealias OpenSettings = @MainActor () -> Void
