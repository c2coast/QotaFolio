import SwiftUI
import QotaFolioCore

@MainActor public func projectedVisibleAccounts(
    _ accounts: [AccountConfig],
    using visibility: any AccountVisibilityControlling
) -> [AccountConfig] {
    accounts.filter { visibility.isVisible($0.id) }
}

/// What the panel shows: the accounts as cards on one glass slab, or the body the catalog's
/// state calls for instead.
public struct PanelContentView: View {
    private let catalog: any AccountCataloging
    private let store: any AccountsStoring
    private let addFlow: any AddFlowPresenting
    private let visibility: any AccountVisibilityControlling
    /// The privacy blanket, when the app has one. Read in `body`, so the names come and go with it.
    private let privacy: ScreenPrivacy?
    /// Whether macOS put the batteries on the bar. Read in `body`; a refusal draws one sentence.
    private let menuBarPlacement: () -> MenuBarPlacement

    @Environment(\.openQotaFolioSettings) private var openSettings
    /// Whether the flow is on the other surface. See `panelPresentsAddFlow` for the rule; the
    /// short version is that the Settings sheet is modal and this panel is a glance surface, so a
    /// user who opens the panel while a flow is up in Settings gets the quota they came for.
    @Environment(\.settingsIsPresentingAddFlow) private var settingsIsPresentingAddFlow
    /// The panel's prompt. See `AccountPromptState` for why it is the panel's and not this view's.
    @Environment(AccountPromptState.self) private var accountPrompt
    @State private var lastManualRefreshAnnouncementID: UInt64?

    public init(
        catalog: any AccountCataloging,
        store: any AccountsStoring,
        addFlow: any AddFlowPresenting,
        visibility: any AccountVisibilityControlling,
        privacy: ScreenPrivacy? = nil,
        menuBarPlacement: @escaping () -> MenuBarPlacement = { .placed }
    ) {
        self.catalog = catalog
        self.store = store
        self.addFlow = addFlow
        self.visibility = visibility
        self.privacy = privacy
        self.menuBarPlacement = menuBarPlacement
    }

    public var body: some View {
        VStack(spacing: 0) {
            if menuBarPlacement() == .hiddenByMenuBarSettings {
                MenuBarPlacementAdvisoryRow()
                    .padding([.horizontal, .top], PanelMetrics.panelPadding)
            }
            content
        }
        .environment(\.namesHidden, privacy?.isBlanketed ?? false)
        .accessibilityElement(children: .contain)
        .onAppear {
            consumeConnectedAnnouncementIfNeeded()
            announceManualRefreshIfNeeded()
        }
        .onChange(of: store.isPanelVisible) { wasVisible, isVisible in
            guard !wasVisible, isVisible else { return }
            consumeConnectedAnnouncementIfNeeded()
        }
        .onChange(of: addFlow.pendingConnectedAnnouncement) { _, announcement in
            guard announcement != nil, store.isPanelVisible else { return }
            consumeConnectedAnnouncementIfNeeded()
        }
        .onChange(of: store.manualRefresh) { _, _ in
            announceManualRefreshIfNeeded()
        }
        .onChange(of: addFlow.activeFlow) { previous, current in
            guard store.isPanelVisible,
                  renderableFlow(previous) != nil,
                  renderableFlow(current) == nil
            else { return }
            AccessibilityAnnouncer.layoutChanged()
        }
    }

    /// The advisory this panel presents, which is not always the one the composition root
    /// published. See `presentedCatalogRecoveryAdvisory`.
    private var presentedAdvisory: CatalogRecoveryAdvisory? {
        presentedCatalogRecoveryAdvisory(
            published: catalog.recoveryAdvisory,
            loadState: catalog.loadState,
            loadCanBeRetried: catalog.loadCanBeRetried
        )
    }

    /// Reads the catalog again and answers whether it is readable now.
    ///
    /// `load()` is the retry. It re-reads exactly when the last read never happened and is a
    /// no-op in every other state, so pressing Try Again after a durable verdict cannot destroy
    /// the rows a failed commit left in memory.
    private func retryCatalogLoad() -> Bool {
        catalog.load()
        return catalog.loadState != .unreadable
    }

    @ViewBuilder private var content: some View {
        switch panelBody(
            loadState: catalog.loadState,
            hasRenderableFlow: panelPresentsAddFlow(
                addFlow.activeFlow,
                settingsIsPresentingAddFlow: settingsIsPresentingAddFlow
            ),
            hasAccountPrompt: promptedAccount(accountPrompt.prompt, in: presentedAccounts) != nil,
            accountCount: catalog.accounts.count,
            visibleAccountCount: presentedAccounts.count
        ) {
        case .catalogUnavailable:
            CatalogUnreadableView(
                advisory: presentedAdvisory,
                canRetry: catalog.loadCanBeRetried,
                retry: retryCatalogLoad
            )
        case .addFlow:
            AddFlowView(addFlow: addFlow)
        case .loading:
            loadingState
        case .noAccounts:
            EmptyStateView(
                catalog: catalog,
                store: store,
                addFlow: addFlow
            )
        case .accountPrompt:
            accountPromptContent
        case .noVisibleAccounts:
            noVisibleAccountsContent
        case .accounts:
            accountListContent
        }
    }

    /// The cards, scrolling when the fleet outgrows the panel, with the footer pinned beneath
    /// them on a soft scroll edge.
    private var accountListContent: some View {
        ScrollView(.vertical) {
            VStack(spacing: PanelMetrics.cardGap) {
                if let advisory = presentedAdvisory {
                    CatalogRecoveryAdvisoryRow(
                        advisory: advisory,
                        loadState: catalog.loadState
                    )
                }

                AccountListView(
                    catalog: catalog,
                    store: store,
                    addFlow: addFlow,
                    visibility: visibility
                )
            }
            .padding(PanelMetrics.panelPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom, spacing: 0) {
            PanelFooterView(
                catalog: catalog,
                store: store,
                addFlow: addFlow,
                hasAccount: true
            )
        }
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .frame(maxHeight: PanelLayout.preferredMaxHeight)
    }

    /// The panel while it waits for an answer about one account.
    ///
    /// Everything else goes: no scrolling list behind the question, and no footer, so there is no
    /// way to start a second change while this one is unanswered. The list itself draws the
    /// prompt, because the list is where every durable account write of the panel is routed
    /// through its permit, and the write belongs next to the permit that admits it.
    private var accountPromptContent: some View {
        AccountListView(
            catalog: catalog,
            store: store,
            addFlow: addFlow,
            visibility: visibility
        )
        .padding(20)
    }

    private var noVisibleAccountsContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text(qfLocalized(
                        "visibility.empty.title",
                        defaultValue: "No visible accounts",
                        comment: "Defensive panel state when configured accounts exist but every account is hidden."
                    ))
                    .font(.title3.weight(.semibold))

                    Text(qfLocalized(
                        "visibility.empty.body",
                        defaultValue: "Your accounts remain connected. Open Settings to show an account in the panel and status strip.",
                        comment: "Explains that hidden accounts remain configured and directs the user to Settings."
                    ))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)

                Button {
                    openSettings()
                } label: {
                    Label(
                        qfLocalized(
                            "visibility.empty.action",
                            defaultValue: "Open Settings…",
                            comment: "Opens Settings from the defensive no-visible-accounts panel state."
                        ),
                        systemImage: "gearshape"
                    )
                    .frame(minWidth: 160, minHeight: 40)
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .padding(24)

            PanelFooterView(
                catalog: catalog,
                store: store,
                addFlow: addFlow,
                hasAccount: true
            )
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(qfLocalized("catalog.loading", defaultValue: "Loading accounts…", comment: "Startup placeholder while the account catalog loads."))
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .accessibilityElement(children: .combine)
    }

    private var presentedAccounts: [AccountConfig] {
        projectedVisibleAccounts(catalog.accounts, using: visibility)
    }

    private func consumeConnectedAnnouncementIfNeeded() {
        guard store.isPanelVisible,
              let accountID = addFlow.consumeConnectedAnnouncement()
        else { return }
        guard visibility.isVisible(accountID) else { return }

        let accountName = catalog.accounts.first(where: { $0.id == accountID })?.name
            ?? qfLocalized("account.generic", defaultValue: "Account", comment: "Generic account name used only if a connected row is not yet visible.")
        AccessibilityAnnouncer.layoutChanged()
        AccessibilityAnnouncer.announce(
            qfLocalized(
                "announce.connected",
                defaultValue: "\(accountName) connected",
                comment: "VoiceOver announcement after an account successfully connects."
            )
        )
    }

    private func announceManualRefreshIfNeeded() {
        guard store.isPanelVisible,
              case .some(.completed(let id, _)) = store.manualRefresh,
              lastManualRefreshAnnouncementID != id
        else { return }
        lastManualRefreshAnnouncementID = id

        let visibleAccounts = presentedAccounts
        guard !visibleAccounts.isEmpty else {
            AccessibilityAnnouncer.announce(
                qfLocalized(
                    "announce.refreshNoVisibleAccounts",
                    defaultValue: "Refresh completed. No accounts are visible.",
                    comment: "VoiceOver announcement after a manual refresh when the defensive zero-visible state is active."
                )
            )
            return
        }

        let unavailable = visibleAccounts.count { account in
            guard let status = store.pollStatus[account.id] else { return true }
            return switch status.phase {
            case .current:
                false
            case .waitingForFirstSnapshot, .stale, .suspendedForReauthentication, .configurationFailure:
                true
            }
        }
        if unavailable == 0 {
            AccessibilityAnnouncer.announce(
                qfLocalized("announce.usageUpdated", defaultValue: "Usage updated", comment: "VoiceOver announcement after a successful manual refresh cohort.")
            )
        } else {
            AccessibilityAnnouncer.announce(
                qfLocalized(
                    "announce.refreshUnavailable",
                    defaultValue: "Refresh completed with \(unavailable) accounts unavailable; cached data shown",
                    comment: "VoiceOver announcement after a manual refresh with unavailable accounts."
                )
            )
        }
    }
}
