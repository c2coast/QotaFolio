import SwiftUI
import QotaFolioCore

/// One account, one card: the provider's mark, the person's name for the account, the plan,
/// and one row per window the provider reports. Nothing on it directs. Behind a click the card
/// grows in place into the instrument, with its chrome pinned.
///
/// The card speaks to VoiceOver as one informational sentence (`AccountAccessibilityPresentation`)
/// and keeps its controls — the actions menu and the state's own affordance — as their own
/// elements beside it.
struct AccountCard: View {
    let account: AccountConfig
    let face: AccountFace
    let store: any AccountsStoring
    let addFlow: any AddFlowPresenting
    let tone: PanelTone
    let isExpanded: Bool
    let isHovered: Bool
    let toggleExpanded: @MainActor () -> Void
    /// The actions menu, drawn by the list because the list owns reorder and the prompt.
    let actions: MoreActionsMenu
    /// The list's namespace for the card chrome, so the surface stays pinned while the card
    /// grows.
    let chrome: Namespace.ID
    /// The carry: how far the identity area has been dragged, in points, down positive. The
    /// list owns what that means — which card parts, where this one lands.
    let liftChanged: @MainActor (CGFloat) -> Void
    let liftEnded: @MainActor (CGFloat) -> Void

    @Environment(AccountPromptState.self) private var panelQuestions: AccountPromptState?
    @Environment(\.openQotaFolioSettings) private var openSettings
    @Environment(\.panelNow) private var panelNow
    @Environment(\.sentenceStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.namesHidden) private var namesHidden

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            stateLine
            if isExpanded {
                AccountInstrument(
                    account: account,
                    face: face,
                    snapshot: store.snapshots[account.id],
                    assessment: store.assessment?.assessment(for: account.id),
                    store: store,
                    tone: tone
                )
                // A dissolve, in place. The instrument is laid out where it will rest and fades
                // in under the rows while the card grows over it; closing runs the same film
                // backwards. Nothing slides: a move would carry the instrument up across the
                // rows, and the card would seem to lift its own contents.
                //
                // The dissolve carries its own curve only where the card's own motion has none:
                // under Reduce Motion the panel takes its new height in one frame, and this fade
                // is then the whole of the change a person is shown.
                .transition(reduceMotion ? .opacity.animation(PanelMotion.dissolve) : .opacity)
            }
        }
        .padding(PanelMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { surface }
        // The card's edge is the reveal. While the height animates, the instrument is shown only
        // where the tile already is — never over the neighbour below, never past the tile's own
        // bottom.
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous))
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous))
        // The whole card is the handle — header, rows, the padding around them — and it is
        // attached before the tap so that it takes precedence: five points of travel and the
        // card is being carried; a press that never travels that far is the tap, and opens the
        // card. The `…` sits in an overlay above this and stays a menu; the state line's
        // buttons keep their own presses.
        .gesture(liftGesture)
        .onTapGesture { toggleExpanded() }
        .overlay(alignment: .topTrailing) {
            actions
                .padding(.top, PanelMetrics.cardPadding + (PanelMetrics.headerHeight - PanelMetrics.hitTarget) / 2)
                .padding(.trailing, PanelMetrics.cardPadding - (PanelMetrics.hitTarget - PanelMetrics.glyphWell) / 2)
        }
        .accessibilityElement(children: .contain)
    }

    /// The plate the card is: frosted, on the panel's one slab of glass, lifting a step under
    /// the pointer. Hover moves nothing.
    @ViewBuilder private var surface: some View {
        PanelPlate(cornerRadius: PanelMetrics.cardRadius, isHovered: isHovered)
            .matchedGeometryEffect(id: "chrome/\(account.id.rawValue.uuidString)", in: chrome)
    }

    // MARK: The summary: what the card says, in one element

    /// The header and the rows, spoken as one sentence. The actions menu floats beside the
    /// header as its own element, and the state's affordance sits under the rows as another.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if case .windows(let levels) = face.body {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(levels) { level in
                        WindowRow(level: level, tone: tone)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken.label)
        .accessibilityValue(spoken.value)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(
            isExpanded
                ? qfLocalized("face.hint.collapse", defaultValue: "Closes the account's history. The actions menu can move it up or down.", comment: "VoiceOver hint on an open account card: what activating does, and that the card can be reordered from its actions menu.")
                : qfLocalized("face.hint.expand", defaultValue: "Opens the account's history. The actions menu can move it up or down.", comment: "VoiceOver hint on a closed account card: what activating does, and that the card can be reordered from its actions menu.")
        )
        .accessibilityAction { toggleExpanded() }
        .accessibilityIdentifier(AXIdentifiers.accountSummary(account.id))
    }

    /// Mark, name, plan — and at the trailing edge the one thing a resting card says about
    /// its state: a spent account's return time, or the instant its last-known numbers were
    /// true at. Room is left for the `…` that floats beside it.
    ///
    /// Room is left for the `…` that floats beside it; the header is part of the face the card
    /// is carried by (`summary`).
    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProviderMark(provider: account.provider)
                    .frame(width: PanelMetrics.markSize, height: PanelMetrics.markSize)
                    .opacity(face.isSpent ? 0.7 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(presentedAccountName(account, namesHidden: namesHidden))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    if let plan = face.planName {
                        Text(plan)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let note = headerNote {
                    Text(note)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            Color.clear.frame(width: PanelMetrics.glyphWell, height: 1)
        }
        .frame(minHeight: PanelMetrics.headerHeight)
    }

    /// Five points of travel begin the carry — a press that drifts less is still a click, and
    /// opens the card; the translation is read in the window's space, so the card moving under
    /// the pointer does not feed back into it.
    private var liftGesture: some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .global)
            .onChanged { liftChanged($0.translation.height) }
            .onEnded { liftEnded($0.translation.height) }
    }

    private var headerNote: String? {
        if face.isSpent {
            guard let back = face.returnsAt else {
                return qfLocalized("face.spent", defaultValue: "Spent", comment: "Header note on an account with nothing spendable now and no return time reported.")
            }
            return qfLocalized(
                "face.backAt",
                defaultValue: "Back at \(PanelWords.clock(back, style: style))",
                comment: "Header note on an account with nothing spendable now: the clock time it comes back."
            )
        }
        if face.isLastKnown, let observedAt = face.observedAt {
            return qfLocalized(
                "face.asOf",
                defaultValue: "As of \(PanelWords.clock(observedAt, style: style))",
                comment: "Header note when the numbers on the card are the last known ones: the clock time they were true at."
            )
        }
        return nil
    }

    // MARK: The state's own line and affordance

    @ViewBuilder private var stateLine: some View {
        switch face.body {
        case .windows:
            if face.needsSignIn {
                signInLine
            } else if face.hasSetupIssue {
                setupIssueLine
            }
        case .needsSignIn:
            signInLine
        case .waitingForFirstReading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                stateText(qfLocalized("face.waiting", defaultValue: "Waiting for the first reading", comment: "State line on an account that is connected and has not answered yet."))
                Spacer(minLength: 0)
            }
            .padding(.top, 1)
        case .setupIssue:
            setupIssueLine
        case .noReading:
            HStack(spacing: 8) {
                stateText(qfLocalized("face.noReading", defaultValue: "No reading", comment: "State line on an account the provider answered nothing usable for."))
                Spacer(minLength: 8)
                Button(qfLocalized("action.retry", defaultValue: "Retry", comment: "Retry refreshing one account.")) {
                    store.requestRefresh(account.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: PanelMetrics.hitTarget)
                .accessibilityIdentifier(AXIdentifiers.accountRetry(account.id))
            }
        }
        if let reason = reconnectRefusalReason {
            ReconnectRefusalCaption(reason: reason)
                .accessibilityIdentifier(AXIdentifiers.accountReconnectRefusal(account.id))
        }
    }

    /// The grant has lapsed: the level cannot be read until the person signs in again. The
    /// button is the state's own affordance, not advice.
    private var signInLine: some View {
        HStack(spacing: 8) {
            stateText(qfLocalized("face.needsSignIn", defaultValue: "Needs sign-in", comment: "State line on an account whose grant has lapsed."))
            Spacer(minLength: 8)
            Button(qfLocalized("face.signIn", defaultValue: "Sign In…", comment: "Button on an account whose grant has lapsed; starts the sign-in again.")) {
                reconnect()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: PanelMetrics.hitTarget)
            .disabled(renderableFlow(addFlow.activeFlow) != nil)
            .help(reconnectRefusalReason ?? "")
            .accessibilityHint(reconnectRefusalReason ?? "")
            .accessibilityIdentifier(AXIdentifiers.accountReauthenticate(account.id))
        }
    }

    private var setupIssueLine: some View {
        HStack(spacing: 8) {
            stateText(qfLocalized("face.setupIssue", defaultValue: "Setup issue", comment: "State line on an account that cannot be polled until it is repaired."))
            Spacer(minLength: 8)
            Button(qfLocalized("face.openSettings", defaultValue: "Open Settings…", comment: "Button on an account with a setup issue; opens QotaFolio Settings.")) {
                openSettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minHeight: PanelMetrics.hitTarget)
            .accessibilityIdentifier(AXIdentifiers.accountOpenSettings(account.id))
        }
    }

    /// The state's words, hidden from VoiceOver because the card's sentence already says them.
    private func stateText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    // MARK: Reconnect, and its answer

    /// Starts the sign-in again, and puts the answer where this card can print it. The row's
    /// actions menu records its own press the same way, so one press has one answer wherever
    /// it was made.
    private func reconnect() {
        recordReconnectAnswer(addFlow.beginReauth(account.id), for: account.id, in: panelQuestions)
    }

    /// The sentence this card prints because a Reconnect press did nothing, or nil. Keyed by
    /// account: five cards can be on screen and only one of them was pressed.
    var reconnectRefusalReason: String? {
        panelQuestions?.reconnectRefusalReason(for: account.id)
    }

    // MARK: One sentence for VoiceOver

    private var spoken: AccountAccessibilityPresentation {
        AccountAccessibilityPresentation.make(
            account: account,
            face: face,
            now: panelNow ?? .now,
            style: style,
            namesHidden: namesHidden
        )
    }
}

/// The answer to a Reconnect press, drawn where the press was made.
///
/// Its own accessibility element, outside the card's combined sentence, so VoiceOver reaches it
/// by ordinary navigation as well as hearing it announced at the moment of the press. It carries
/// no `lineLimit`: a sentence that needs two lines gets two lines, at any text size.
struct ReconnectRefusalCaption: View {
    let reason: String

    var body: some View {
        Label(reason, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
