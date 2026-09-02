import Foundation

/// The ChatGPT device code as it has to be HEARD: one character at a time.
///
/// `A1B2-C3D4` read as a word is a noise, and the user's whole task at that step is to transcribe
/// it into a browser. Spelled out, every character arrives on its own.
///
/// One derivation with two readers. `DeviceCodeStep` publishes it as the code's
/// `accessibilityValue`, and `addFlowArrivalAnnouncement` ends the device-code sentence with it,
/// so what a user reads off the element and what they hear on arrival cannot be two codes.
public nonisolated func spokenDeviceCode(_ userCode: String) -> String {
    userCode.map { character in
        character == "-" ? "hyphen" : String(character)
    }.joined(separator: ", ")
}

/// What the add flow says when a step arrives, or nil for a step that has nothing worth hearing.
///
/// A sighted user watches the panel's body change and knows where they are. A VoiceOver user is
/// moved without being told: the control they pressed is destroyed by the transition, so their
/// cursor is standing on nothing and no sentence explains the new step. This is that sentence, for
/// the steps that need one.
///
/// **Silence is a decision here, not an omission.** `.exchanging` and `.storing` are two automatic
/// sub-states of one operation the user is not taking part in — they arrive back-to-back while the
/// user is still in the browser this app sent them to, they offer nothing to do, and they are
/// bracketed by two sentences that ARE heard: the hand-off above them and the outcome below.
/// Announcing them would be a running commentary, which for a screen-reader user is worse than
/// nothing: each announcement interrupts the last, and the one that matters arrives in fragments.
/// The app's own grain agrees — `PanelFlowStep` collapses all three progress phases into one step,
/// because they are one step, and `AuthProgressStep` renders all three from one view.
///
/// `.connected` is silent for a different reason: it has an owner. `AddFlowPresenting`'s
/// `pendingConnectedAnnouncement` is set on every completed add and consumed atomically by whoever
/// is on screen, which is what makes one add produce exactly one "connected" — never zero, never
/// stale, never twice. A sentence here would be the third producer of that announcement, arriving
/// from a new direction, and `consumeConnectedAnnouncement` exists to prevent exactly that.
/// `renderableFlow` already drops the phase before it reaches a view; this returns nil so the
/// projection stays total and says WHY rather than relying on a caller to remember.
///
/// - Parameters:
///   - phase: the step that has just arrived.
///   - provider: the provider this flow signs in to. It names the provider in the starting
///     sentence and selects the failure taxonomy's per-provider copy.
///   - now: read only by the failure taxonomy, whose rate-limit copy counts down.
public nonisolated func addFlowArrivalAnnouncement(
    _ phase: AccountFlowPhase,
    provider: AccountProvider,
    now: ContinuousClock.Instant
) -> String? {
    switch phase {
    case .naming:
        // The step's own heading, not a second sentence about it. `AuthFailureStep`'s title is
        // announced the same way, and one string cannot disagree with itself.
        return qfLocalized(
            "auth.add.heading",
            defaultValue: "Add an account",
            comment: "Heading for the add-account naming step."
        )

    case .starting:
        // The answer to the Continue press. Without it the press that starts a sign-in is the one
        // press on this panel that says nothing at all: the naming step leaves the screen, the
        // Continue button is destroyed, and a VoiceOver user is left standing on a dead element.
        return qfLocalized(
            "announce.auth.starting",
            defaultValue: "Starting sign-in to \(providerName(provider))",
            comment: "VoiceOver announcement when a sign-in starts and the naming step is replaced by the progress step."
        )

    case .anthropicWaitingInBrowser(let authorizationURL):
        // The hand-off. This is the sentence that decides whether the user knows to go to their
        // browser or is simply stranded, and the panel survives the hand-off, so "QotaFolio is
        // waiting" is a promise the app keeps. Only the HOST is spoken: the query carries the live
        // CSRF state and the PKCE challenge, which are never rendered anywhere.
        return qfLocalized(
            "announce.auth.anthropicBrowser",
            defaultValue: "Finish signing in to \(authorizationURL.host() ?? "claude.ai") in your browser. QotaFolio is waiting.",
            comment: "VoiceOver announcement when the Anthropic sign-in hands the user to their browser. Only the host is spoken."
        )

    case .openAIAwaitingDevice(let userCode, _, _):
        // The one credential-adjacent value this app displays on purpose, and the user has to copy
        // it by hand. The sentence says what to do first and ends with the code, so nothing follows
        // the characters they are trying to write down.
        return qfLocalized(
            "announce.auth.deviceCode",
            defaultValue: "Enter this code on the ChatGPT authorization page in your browser: \(spokenDeviceCode(userCode))",
            comment: "VoiceOver announcement when the ChatGPT device code appears. The code is spelled one character at a time so it can be transcribed."
        )

    case .exchanging, .storing:
        return nil

    case .connected:
        return nil

    case .failed(.cancelled):
        // The user cancelled, from a control on this surface, so they already know. `renderableFlow`
        // drops this phase before any view sees it.
        return nil

    case .failed(let failure):
        // The failure taxonomy's own title, so that the whole flow has ONE producer of arrival
        // announcements. `onAppear` answers a different question — "did this view appear?" — and
        // it answers it wrong twice: a second, different failure reuses the same view identity and
        // is never announced, and a view that appears again re-announces a failure the user heard
        // already.
        return AuthFailurePresentation.make(failure: failure, provider: provider, now: now).title
    }
}

/// The provider's name as this app writes it everywhere else.
private nonisolated func providerName(_ provider: AccountProvider) -> String {
    provider == .anthropic
        ? qfLocalized("provider.anthropic", defaultValue: "Anthropic", comment: "Anthropic provider name.")
        : qfLocalized("provider.openai", defaultValue: "ChatGPT", comment: "ChatGPT provider name.")
}
