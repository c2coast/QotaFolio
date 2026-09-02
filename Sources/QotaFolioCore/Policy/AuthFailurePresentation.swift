import Foundation

// The sign-in failure taxonomy. Every AccountFlowFailure — including the `.deadlineExpired` provider branch and the
// DeviceCodeStartFailure.rateLimited retry gate — is projected here, as a pure function of (failure, provider, now).
//
// Every comparable projection in this app (StatusStripModel, AccountAccessibilityPresentation, AccountFace,
// ResetCountdown, RetryCountdown) is a pure nonisolated function in Policy, and so is this one.
//
// The retry gate's deadline is not held here. AddFlowView renders every `.failed` phase from ONE ViewBuilder branch, so
// SwiftUI reuses the view identity across successive failures and a `@State` initial value is discarded for an identity
// that already exists — a second, longer rate-limit failure would inherit the first attempt's already-expired deadline
// and render an ENABLED "Try again" button with no wait text while the provider was still rate-limiting.
// `DeviceCodeStartFailure.rateLimited` carries the ABSOLUTE instant the provider imposed instead. There is nothing here
// to anchor, so there is no anchor to go stale — and two rate limits that differ only in when they arrived are
// different values.

public nonisolated struct AuthFailurePresentation: Equatable, Sendable {
    // The affordance offered for this failure. Each rendering case carries its own permanent accessibility identifier, so the
    // renderer has no optional to unwrap and no path that has to invent one.
    public enum Action: Equatable, Sendable {
        case none
        case retry(enabled: Bool, accessibilityIdentifier: String)
        case newCode(accessibilityIdentifier: String)
    }

    public let title: String
    public let detail: String
    public let supporting: String?
    public let actionTitle: String
    public let action: Action

    /// The live state of the rate-limit retry gate, or nil for a failure that carries no gate.
    /// The view reads this to decide whether a per-second re-render is worth running. It is a report, not an authority:
    /// the enabled-state in `action` and the copy in `supporting` are already decided from the same derivation.
    public let retryWindow: RetryCountdown.State?

    public init(
        title: String,
        detail: String,
        supporting: String?,
        actionTitle: String,
        action: Action,
        retryWindow: RetryCountdown.State?
    ) {
        self.title = title
        self.detail = detail
        self.supporting = supporting
        self.actionTitle = actionTitle
        self.action = action
        self.retryWindow = retryWindow
    }

    /// Whether the offered affordance can be used right now. `.none` offers nothing, so it is never usable.
    public var isActionEnabled: Bool {
        switch action {
        case .none: false
        case .retry(let enabled, _): enabled
        case .newCode: true
        }
    }

    /// True while the retry gate is still counting down, so the rendered copy changes every second.
    public var isCountingDown: Bool {
        if case .waiting = retryWindow { return true }
        return false
    }

    /// The permanent accessibility identifier of the retry affordance, which differs per provider.
    public static func retryAccessibilityIdentifier(
        for provider: AccountProvider
    ) -> String {
        provider == .anthropic ? AXIdentifiers.anthropicRetry : AXIdentifiers.chatGPTRetry
    }

    public static func make(
        failure: AccountFlowFailure,
        provider: AccountProvider,
        now: ContinuousClock.Instant
    ) -> AuthFailurePresentation {
        switch failure {
        case .browserOpenFailed:
            // On this path the listener and the transaction are already dead, so retry is the ONLY affordance.
            return retryPresentation(
                title: qfLocalized("auth.fail.browserOpen", defaultValue: "Couldn't open your browser", comment: "Anthropic authorization browser could not open."),
                detail: qfLocalized("auth.fail.browserOpen.detail", defaultValue: "Start a fresh sign-in attempt.", comment: "A browser-open failure ends the current Anthropic transaction."),
                actionTitle: qfLocalized("action.tryAgain", defaultValue: "Try again", comment: "Start a fresh attempt after a failure."),
                provider: provider
            )

        case .startFailed(.unavailable):
            return AuthFailurePresentation(
                title: qfLocalized("auth.fail.deviceUnavailable", defaultValue: "Device-code sign-in is turned off", comment: "ChatGPT device-code sign-in is disabled by the account or workspace."),
                detail: qfLocalized("auth.fail.deviceUnavailable.detail", defaultValue: "QotaFolio can't add this ChatGPT account until its security setting or workspace policy changes.", comment: "ChatGPT device-code admin/security failure explanation."),
                supporting: qfLocalized("auth.fail.readOnlyScope", defaultValue: "QotaFolio only reads usage. It never posts, changes account settings, or signs you out.", comment: "Read-only reassurance after device-code sign-in is unavailable."),
                actionTitle: "",
                action: .none,
                retryWindow: nil
            )

        case .startFailed(.rateLimited(let retryAt)):
            // The retry affordance is DISABLED for a known countdown; the coordinator never auto-retries.
            // The deadline is the provider's own, carried by the failure. It is read, never computed.
            let countdown = RetryCountdown(deadline: retryAt)
            return AuthFailurePresentation(
                title: qfLocalized("auth.fail.rateLimited", defaultValue: "Too many attempts", comment: "ChatGPT device-code start was rate-limited."),
                detail: qfLocalized("auth.fail.rateLimited.detail", defaultValue: "Try again shortly.", comment: "Rate-limited device-code start guidance."),
                supporting: countdown.remainingText(at: now),
                actionTitle: qfLocalized("action.tryAgain", defaultValue: "Try again", comment: "Start a fresh attempt after a failure."),
                action: .retry(
                    enabled: countdown.isEnabled(at: now),
                    accessibilityIdentifier: retryAccessibilityIdentifier(for: provider)
                ),
                retryWindow: countdown.state(at: now)
            )

        case .startFailed(.transport):
            return retryPresentation(
                title: qfLocalized("auth.fail.startTransport", defaultValue: "Couldn't reach ChatGPT", comment: "ChatGPT device-code start transport failure."),
                detail: qfLocalized("auth.fail.startTransport.detail", defaultValue: "Check your connection and try again.", comment: "Device-code start transport guidance."),
                actionTitle: qfLocalized("action.tryAgain", defaultValue: "Try again", comment: "Start a fresh attempt after a failure."),
                provider: provider
            )

        case .deadlineExpired:
            if provider == .openai {
                return AuthFailurePresentation(
                    title: qfLocalized("auth.fail.expired", defaultValue: "This sign-in request expired", comment: "Provider sign-in deadline expired."),
                    detail: qfLocalized("auth.fail.expired.chatgpt", defaultValue: "Get a new ChatGPT device code to continue.", comment: "ChatGPT deadline-expired guidance."),
                    supporting: nil,
                    actionTitle: qfLocalized("auth.chatgpt.getNewCode", defaultValue: "Get a new code", comment: "Request a fresh ChatGPT device code."),
                    action: .newCode(accessibilityIdentifier: AXIdentifiers.chatGPTGetNewCode),
                    retryWindow: nil
                )
            }
            return retryPresentation(
                title: qfLocalized("auth.fail.expired", defaultValue: "This sign-in request expired", comment: "Provider sign-in deadline expired."),
                detail: qfLocalized("auth.fail.expired.anthropic", defaultValue: "Start a fresh Anthropic sign-in attempt.", comment: "Anthropic deadline-expired guidance."),
                actionTitle: qfLocalized("action.tryAgain", defaultValue: "Try again", comment: "Start a fresh attempt after a failure."),
                provider: provider
            )

        case .denied:
            return retryPresentation(
                title: qfLocalized("auth.fail.denied", defaultValue: "Sign-in was denied", comment: "Provider denied authorization."),
                detail: qfLocalized("auth.fail.denied.detail", defaultValue: "Start over when you're ready.", comment: "Provider authorization denial guidance."),
                actionTitle: qfLocalized("action.startOver", defaultValue: "Start over", comment: "Start a fresh provider sign-in after a terminal failure."),
                provider: provider
            )

        case .listenerUnavailable:
            return retryPresentation(
                title: qfLocalized("auth.fail.listener", defaultValue: "Couldn't start the local sign-in listener", comment: "Anthropic loopback listener could not start."),
                detail: qfLocalized("auth.fail.listener.detail", defaultValue: "Try again. If this persists, check the app's network permissions.", comment: "Anthropic loopback listener failure guidance."),
                actionTitle: qfLocalized("action.tryAgain", defaultValue: "Try again", comment: "Start a fresh attempt after a failure."),
                provider: provider
            )

        case .exchangeFailed:
            return retryPresentation(
                title: qfLocalized("auth.fail.exchange", defaultValue: "Couldn't complete sign-in", comment: "Provider token exchange failed."),
                detail: qfLocalized("auth.fail.exchange.detail", defaultValue: "The authorization code can't be reused. Start over.", comment: "Single-use token exchange failure guidance."),
                actionTitle: qfLocalized("action.startOver", defaultValue: "Start over", comment: "Start a fresh provider sign-in after a terminal failure."),
                provider: provider
            )

        case .scopeNotGranted:
            // Anthropic signed the user in and withheld the one permission QotaFolio asks
            // for. "Try again" is the wrong instruction — the same flow grants the same
            // nothing — so the action names what has to change instead.
            return retryPresentation(
                title: qfLocalized("auth.fail.scope", defaultValue: "QotaFolio wasn't given permission to read your usage", comment: "The provider granted the sign-in but withheld the profile permission."),
                detail: qfLocalized("auth.fail.scope.detail", defaultValue: "Sign in again and approve the request to see your account's quota.", comment: "Guidance when the granted scope is short of the requested one."),
                actionTitle: qfLocalized("action.startOver", defaultValue: "Start over", comment: "Start a fresh provider sign-in after a terminal failure."),
                provider: provider
            )

        case .storeFailed:
            // The Keychain write was attempted and rejected. Deliberately distinct from .storageUnavailable below.
            return retryPresentation(
                title: qfLocalized("auth.fail.store", defaultValue: "Couldn't save your sign-in", comment: "Keychain credential write failed."),
                detail: qfLocalized("auth.fail.store.detail", defaultValue: "QotaFolio couldn't save the credential to this Mac's Keychain.", comment: "Credential write failure guidance."),
                actionTitle: qfLocalized("action.tryAgain", defaultValue: "Try again", comment: "Start a fresh attempt after a failure."),
                provider: provider
            )

        case .alreadyConnected(let accountName):
            // One sentence, and it names the account. There is nothing to retry — the same
            // sign-in grants the same account — so the step offers only its Dismiss button, and
            // nothing was added or changed.
            return AuthFailurePresentation(
                title: qfLocalized("auth.fail.alreadyConnected", defaultValue: "You have already added this account", comment: "The grant just made belongs to a provider account the app already holds."),
                detail: qfLocalized("auth.fail.alreadyConnected.detail", defaultValue: "This sign-in is the same account as \(accountName), so nothing was added.", comment: "Names the existing account a duplicate sign-in collides with."),
                supporting: nil,
                actionTitle: "",
                action: .none,
                retryWindow: nil
            )

        case .storageUnavailable:
            // "Could not write NOW" is not "the write failed". This copy is user-actionable and must stay distinct.
            return retryPresentation(
                title: qfLocalized("auth.fail.storageUnavailable", defaultValue: "Your Keychain is locked", comment: "Keychain is temporarily unavailable during credential storage."),
                detail: qfLocalized("auth.fail.storageUnavailable.detail", defaultValue: "Unlock your Mac and try again so QotaFolio can save your sign-in.", comment: "Actionable Keychain-unavailable guidance."),
                actionTitle: qfLocalized("action.tryAgain", defaultValue: "Try again", comment: "Start a fresh attempt after a failure."),
                provider: provider
            )

        case .cancelled:
            // `renderableFlow` drops this phase before it reaches a view. The projection stays total.
            return AuthFailurePresentation(
                title: "",
                detail: "",
                supporting: nil,
                actionTitle: "",
                action: .none,
                retryWindow: nil
            )
        }
    }

    private static func retryPresentation(
        title: String,
        detail: String,
        actionTitle: String,
        provider: AccountProvider
    ) -> AuthFailurePresentation {
        AuthFailurePresentation(
            title: title,
            detail: detail,
            supporting: nil,
            actionTitle: actionTitle,
            action: .retry(
                enabled: true,
                accessibilityIdentifier: retryAccessibilityIdentifier(for: provider)
            ),
            retryWindow: nil
        )
    }
}
