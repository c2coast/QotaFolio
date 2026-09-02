import SwiftUI
import QotaFolioCore

public struct AddFlowView: View {
    private let addFlow: any AddFlowPresenting

    @State private var name = ""
    @State private var selectedProvider: AccountProvider = .anthropic
    /// The sentence this view has already spoken about the flow that is running.
    ///
    /// The SENTENCE, not the phase, and that distinction was measured rather than guessed. The
    /// accessibility probe reported one ChatGPT device code twice, with the
    /// same code and a deadline a few seconds further out. Two phases, not equal, and the user's
    /// code had not changed — so a phase-keyed record spelled the same nine characters at them a
    /// second time. What must not repeat is what they hear, so that is what is recorded. A phase
    /// that changes without changing what there is to say is not an arrival.
    ///
    /// The two triggers below can both fire for one arrival; this is what makes them produce one
    /// sentence rather than two. It is the shape `consumeConnectedAnnouncement` gave the connected
    /// announcement, for the same reason and under the same rule: one arrival, exactly one
    /// announcement, never zero and never stale.
    ///
    /// It is deliberately NOT cleared when the panel is hidden. A user who hides the panel and
    /// opens it again on the same step has already been told what that step is, and saying it
    /// again on every look is the running commentary this funnel exists to avoid.
    @State private var announcedArrival: String?

    /// Whether this rendering of the flow is the one the user can see.
    ///
    /// The add flow has TWO surfaces and both stay live: the panel renders it, and the Settings
    /// window renders it in a sheet after Settings has hidden the panel. Each surface answers this
    /// for itself, so the flow does not have to work out which one it is standing on: a countdown
    /// that copies the underlying panel flag instead freezes on the Settings surface.
    @Environment(\.surfaceIsOnScreen) private var surfaceIsOnScreen

    public init(addFlow: any AddFlowPresenting) {
        self.addFlow = addFlow
    }

    public var body: some View {
        Group {
            if let phase = renderableFlow(addFlow.activeFlow) {
                phaseView(phase)
                    .padding(PanelMetrics.cardPadding + 4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background { PanelPlate() }
            }
        }
        .padding(PanelMetrics.panelPadding)
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        // TWO TRIGGERS, ONE ANNOUNCEMENT. A step arrives while this surface is on screen, or this
        // surface comes on screen holding a step it has not spoken. The second is not decoration:
        // a browser hand-back re-presents a panel the system had taken off screen, and the failure
        // it hands back is the announcement in this flow a user can least afford to miss.
        // `announcedArrival` makes whichever fires first the only one that speaks.
        .onChange(of: addFlow.activeFlow, initial: true) { _, _ in
            announceArrivalIfNeeded()
        }
        .onChange(of: surfaceIsOnScreen) { _, _ in
            announceArrivalIfNeeded()
        }
    }

    /// Says where the user now is, once per arrival.
    ///
    /// Focus is not moved, and the reason is not caution. Every destination is worse than the one
    /// the user is on:
    ///
    ///   * The progress step's only control is **Cancel** — the one thing they must not press.
    ///   * A heading is not a control, so a user put there has to navigate off it before they can
    ///     press anything, and every step already carries `.isHeader`, which is the rotor route to
    ///     the same place at the moment they want it rather than at the moment we chose.
    ///   * The step a user is most often moved through is `.starting`, which is replaced again a
    ///     second later. Focus placed there is yanked twice for one sign-in.
    ///   * Worst: `.anthropicWaitingInBrowser` arrives as the browser takes the foreground. Moving
    ///     assistive focus then would pull the user's VoiceOver cursor out of the sign-in page this
    ///     app just sent them to.
    ///
    /// So the sentence is announced, the layout change says the elements under them are new, and
    /// where they go next stays theirs.
    private func announceArrivalIfNeeded() {
        // A flow that is over takes its record with it, so the next add starts with nothing said.
        // Above the surface guard on purpose: the record is about the flow, not about who is
        // looking at it, and a flow that ended while the panel was hidden must not silence the
        // next one's first step.
        guard let phase = renderableFlow(addFlow.activeFlow) else {
            announcedArrival = nil
            return
        }
        // A rendering nobody can see says nothing. Both surfaces stay live; only one is on screen.
        guard surfaceIsOnScreen else { return }
        guard let arrival = addFlowArrivalAnnouncement(
            phase,
            provider: flowProvider,
            now: ContinuousClock.now
        ) else { return }
        guard arrival != announcedArrival else { return }
        announcedArrival = arrival

        AccessibilityAnnouncer.layoutChanged()
        AccessibilityAnnouncer.announce(arrival)
    }

    @ViewBuilder private func phaseView(_ phase: AccountFlowPhase) -> some View {
        switch phase {
        case .naming:
            NameProviderStep(
                name: $name,
                provider: $selectedProvider,
                refusalReason: addFlow.addFlowRefusal.map(addFlowRefusalReason),
                // `submitAdd` answers, and the answer is spoken at the moment of the press. The
                // caption beside this button is drawn from `addFlowRefusal`, and a caption on
                // its own leaves a VoiceOver user pressing Continue, hearing nothing, and going
                // exploring to learn that anything happened at all.
                //
                // A refusal leaves the phase at `.naming`, so the arrival funnel above stays
                // quiet and this is the only sentence the press produces. An ACCEPTED Continue
                // answers nil here and moves the phase, and the funnel speaks instead. Either
                // way the press produces exactly one announcement.
                continueAction: {
                    recordAddSubmissionAnswer(
                        addFlow.submitAdd(
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            provider: selectedProvider
                        )
                    )
                },
                cancel: { addFlow.cancelActiveFlow(.userCancel) }
            )

        case .starting, .exchanging:
            AuthProgressStep(
                phase: phase,
                provider: flowProvider,
                cancel: { addFlow.cancelActiveFlow(.userCancel) }
            )

        case .storing:
            AuthProgressStep(
                phase: phase,
                provider: flowProvider,
                cancel: nil
            )

        case .anthropicWaitingInBrowser(let authorizationURL):
            AnthropicBrowserStep(
                authorizationURL: authorizationURL,
                reopen: { addFlow.reopenAuthorizationBrowser() },
                cancel: { addFlow.cancelActiveFlow(.userCancel) }
            )

        case .openAIAwaitingDevice(let userCode, let verificationURL, let expiresAt):
            DeviceCodeStep(
                userCode: userCode,
                verificationURL: verificationURL,
                expiresAt: expiresAt,
                requestNewCode: { addFlow.requestNewDeviceCode() },
                cancel: { addFlow.cancelActiveFlow(.userCancel) }
            )

        case .connected:
            EmptyView()

        case .failed(let failure):
            if failure != .cancelled {
                AuthFailureStep(
                    failure: failure,
                    provider: flowProvider,
                    retry: { addFlow.retryActiveFlow() },
                    requestNewDeviceCode: { addFlow.requestNewDeviceCode() },
                    dismiss: { addFlow.acknowledgeFailure() }
                )
            }
        }
    }

    private var flowProvider: AccountProvider {
        addFlow.activeFlowProvider ?? selectedProvider
    }
}
