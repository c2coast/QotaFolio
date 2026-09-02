import SwiftUI
import QotaFolioCore

// The terminal sign-in failure step. The taxonomy it renders — title, detail, supporting text, affordance and enabled-state for
// every AccountFlowFailure — lives in QotaFolioCore's AuthFailurePresentation. This type renders that projection and nothing more.
//
// It holds no state. AddFlowView draws every `.failed` phase from one ViewBuilder branch, so this view's identity is reused
// across successive failures — and that is harmless, because there is nothing for a reused identity to carry over. The
// rate-limit deadline travels inside the failure itself, so every render answers from the failure on screen and the clock.
public struct AuthFailureStep: View {
    public let failure: AccountFlowFailure
    public let provider: AccountProvider
    public let retry: () -> Void
    public let requestNewDeviceCode: () -> Void
    public let dismiss: () -> Void

    /// Not "is the panel open". This step is rendered on two surfaces — the panel and the Settings
    /// sheet — and the panel's answer is wrong on the other one, where it freezes the retry
    /// countdown. A frozen retry countdown is worse than a frozen clock: it is the gate that tells
    /// a user when they may press again, and stuck it either says "wait" for ever or says "go"
    /// while the provider is still refusing.
    @Environment(\.surfaceIsOnScreen) private var surfaceIsOnScreen

    public init(
        failure: AccountFlowFailure,
        provider: AccountProvider,
        retry: @escaping () -> Void,
        requestNewDeviceCode: @escaping () -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.failure = failure
        self.provider = provider
        self.retry = retry
        self.requestNewDeviceCode = requestNewDeviceCode
        self.dismiss = dismiss
    }

    public var body: some View {
        let presentation = makePresentation(now: ContinuousClock.now)
        Group {
            // A gate that is still counting is the only thing here that changes once a second, so
            // it is the only thing that gets a clock. The remaining seconds come from the gate's
            // own derivation and bound the schedule: it ends one entry past zero, on the render
            // that re-enables Try again, instead of waking every second for ever afterwards.
            // Nothing a user reads is derived from that bound — the copy and the enabled-state are
            // re-derived on every tick from the provider's absolute deadline and the clock.
            if surfaceIsOnScreen, case .waiting(let remainingSeconds)? = presentation.retryWindow {
                TimelineView(.explicit(ticks(remainingSeconds))) { _ in
                    content(makePresentation(now: ContinuousClock.now))
                }
            } else {
                content(presentation)
            }
        }
        // This step's title is announced by `AddFlowView`, with every other step's, not from
        // here. `onAppear` answers "did this view appear?", which is not the question — and it
        // gives the wrong answer in both directions. A second, DIFFERENT failure reuses this
        // view's identity (see the note above), so it appears once and is announced once while
        // the user is told about the first failure only; and a view that appears a second time
        // re-announces a failure already heard. The funnel answers "did a step arrive?", which is
        // the question, and it holds the whole flow to one announcement per arrival.
    }

    var retryIdentifier: String {
        AuthFailurePresentation.retryAccessibilityIdentifier(for: provider)
    }

    /// One tick a second for the seconds the gate has left, plus the one that re-enables it.
    ///
    /// A periodic schedule never ends, so a periodic countdown would keep waking the process
    /// every second after the gate opened — for as long as the surface stayed open, which on the
    /// Settings sheet is until the user dismisses it. The count is the gate's own remaining
    /// seconds, not a second reading of the deadline, so there is no derived instant here to go
    /// stale. It decides only when to stop asking: every value a user reads is re-derived on each
    /// tick from the provider's absolute deadline and the clock.
    ///
    /// Two entries past the last changing number, not one. `ExplicitTimelineSchedule` does not
    /// render its LAST entry — it uses it as the end of the one before, which was measured
    /// rather than assumed — so one of the two is the render that re-enables Try again
    /// and the other is the terminator that lets it happen. A schedule that stopped at zero would
    /// leave the button dead with the gate open, which is the stuck-countdown defect again.
    private func ticks(_ remainingSeconds: Int64) -> UnfoldFirstSequence<Date> {
        var remaining = remainingSeconds + 1
        return sequence(first: Date.now) { previous in
            guard remaining > 0 else { return nil }
            remaining -= 1
            return previous.addingTimeInterval(1)
        }
    }

    private func makePresentation(now: ContinuousClock.Instant) -> AuthFailurePresentation {
        AuthFailurePresentation.make(failure: failure, provider: provider, now: now)
    }

    private func content(_ presentation: AuthFailurePresentation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text(presentation.title)
                    .font(.title3.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(AXIdentifiers.authError)

            Text(presentation.detail)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let supporting = presentation.supporting {
                Text(supporting)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(
                    qfLocalized("action.dismiss", defaultValue: "Dismiss", comment: "Dismiss a terminal sign-in failure."),
                    action: dismiss
                )
                .keyboardShortcut(.cancelAction)
                .frame(minWidth: 40, minHeight: 40)
                .accessibilityIdentifier(AXIdentifiers.authDismissFailure)

                Spacer()

                switch presentation.action {
                case .none:
                    EmptyView()
                case .retry(let enabled, let accessibilityIdentifier):
                    actionButton(
                        title: presentation.actionTitle,
                        accessibilityIdentifier: accessibilityIdentifier,
                        action: retry
                    )
                    .disabled(!enabled)
                case .newCode(let accessibilityIdentifier):
                    actionButton(
                        title: presentation.actionTitle,
                        accessibilityIdentifier: accessibilityIdentifier,
                        action: requestNewDeviceCode
                    )
                }
            }
        }
    }

    private func actionButton(
        title: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .frame(minWidth: 40, minHeight: 40)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
