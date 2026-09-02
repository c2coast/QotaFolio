import SwiftUI
import QotaFolioCore

/// The accounts as cards, in the user's order, on the panel's glass.
///
/// The list owns what is shared between cards: which one is hovered, which one is open, which
/// one has the keyboard, the carry that reorders them, and the prompt that replaces them while
/// a rename or a removal waits for an answer. It runs the panel's one clock and, because a card's
/// height follows its content, it measures itself and tells the panel when that changes.
public struct AccountListView: View {
    private let catalog: any AccountCataloging
    private let store: any AccountsStoring
    private let addFlow: any AddFlowPresenting
    private let visibility: any AccountVisibilityControlling

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.requestPanelResize) private var requestPanelResize
    /// The panel's prompt, not this view's.
    ///
    /// `MenuBarPanelController` owns it and clears it whenever the panel leaves the screen. Held
    /// as `@State` here it would outlive the panel's visit — the hosting controller is built once
    /// and never torn down — and the next visit would open on a destructive question the user
    /// never asked.
    @Environment(AccountPromptState.self) private var accountPrompt

    @State private var hovered: AccountID?
    @State private var expanded: AccountID?
    @State private var rowHeights: [AccountID: Double] = [:]
    @State private var listHeight: Double = 0
    /// The card being carried, and where it would land if let go now.
    @State private var lift: Lift?
    @FocusState private var focusedCard: AccountID?
    /// The card chrome's namespace: a card springs open with its surface matched, so the chrome
    /// stays pinned while the card grows.
    @Namespace private var chrome
    /// A card under the pointer. `gap` is the slot it would drop into — the gap
    /// `reorderedIDs(_:moving:toGap:)` takes — and it is what the other cards part for.
    struct Lift: Equatable {
        let id: AccountID
        let index: Int
        var translation: CGFloat
        var gap: Int
    }

    /// Whether the keyboard has spoken since the panel opened or the pointer last moved.
    ///
    /// Focus lands on the first card when the panel opens, and the Mac's own rule is to draw
    /// nothing for it until the keyboard is used. So the ring is drawn here, not by the system:
    /// the first arrow key shows it where focus already is, the next ones move it, and the
    /// pointer's return hides it again.
    @State private var keyboardFocusVisible = false

    public init(
        catalog: any AccountCataloging,
        store: any AccountsStoring,
        addFlow: any AddFlowPresenting,
        visibility: any AccountVisibilityControlling
    ) {
        self.catalog = catalog
        self.store = store
        self.addFlow = addFlow
        self.visibility = visibility
        #if DEBUG
        // The fixture runtime's way of photographing an open or hovered card without a pointer.
        let environment = ProcessInfo.processInfo.environment
        if let name = environment["QOTAFOLIO_UI_EXPANDED"],
           let account = catalog.accounts.first(where: { $0.name == name }) {
            _expanded = State(initialValue: account.id)
        }
        if let name = environment["QOTAFOLIO_UI_HOVER"],
           let account = catalog.accounts.first(where: { $0.name == name }) {
            _hovered = State(initialValue: account.id)
        }
        #endif
    }

    public var body: some View {
        Group {
            if let account = promptedAccount(accountPrompt.prompt, in: presentedAccounts) {
                // The prompt replaces the rows rather than floating over them. While it is on
                // screen no other control of the panel is reachable, so no second question and no
                // add flow can start behind the one waiting for an answer.
                promptContent(account)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AXIdentifiers.accountPrompt)
            } else {
                PanelClock {
                    rowsContent()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AXIdentifiers.accountList)
            }
        }
    }

    private var tone: PanelTone { PanelTone(scheme: colorScheme, contrast: contrast) }

    private func rowsContent() -> some View {
        let accounts = presentedAccounts
        return VStack(spacing: PanelMetrics.cardGap) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                card(account: account, index: index, of: accounts)
                    .onGeometryChange(for: Double.self) { proxy in
                        Double(proxy.size.height)
                    } action: { rowHeights[account.id] = $0 }
            }
        }
        // The card's own height report. This is the content whose height moves: a window the
        // provider added, a state line that came or went, an instrument opened. Measured, not
        // described, so there is one derivation of the height and nothing to keep in step with it.
        .onGeometryChange(for: Double.self) { proxy in
            Double(proxy.size.height)
        } action: { height in
            guard height != listHeight else { return }
            listHeight = height
            requestPanelResize()
        }
        .onChange(of: store.isPanelVisible) { _, visible in
            // Each visit starts the same way: focus on the first card, ring hidden, nothing carried.
            if !visible {
                keyboardFocusVisible = false
                focusedCard = nil
                lift = nil
            }
        }
        .onChange(of: accounts.map(\.id)) { _, ids in
            if let expanded, !ids.contains(expanded) { self.expanded = nil }
        }
        #if DEBUG
        // The lab's card toggle, arriving by the same path a tap takes.
        .onReceive(NotificationCenter.default.publisher(for: DebugCardToggle.notification)) { note in
            guard let name = note.userInfo?[DebugCardToggle.accountNameKey] as? String,
                  let account = accounts.first(where: { $0.name == name })
            else { return }
            toggle(account.id)
        }
        #endif
    }

    private func card(account: AccountConfig, index: Int, of accounts: [AccountConfig]) -> some View {
        let face = AccountFace.make(
            account: account,
            snapshot: store.snapshots[account.id],
            status: store.pollStatus[account.id]
        )
        let isLifted = lift?.id == account.id
        return AccountCard(
            account: account,
            face: face,
            store: store,
            addFlow: addFlow,
            tone: tone,
            isExpanded: expanded == account.id,
            isHovered: hovered == account.id,
            toggleExpanded: { toggle(account.id) },
            actions: MoreActionsMenu(
                account: account,
                canMoveUp: index > 0,
                canMoveDown: index < accounts.count - 1,
                mutationBlocked: catalog.loadState == .unreadable,
                blockedReason: nil,
                flowBlocked: renderableFlow(addFlow.activeFlow) != nil,
                rename: { accountPrompt.ask(.rename(account.id)) },
                // The menu's `reconnect` answers, so this closure carries the answer out rather
                // than discarding it. The menu records it against the row it belongs to.
                reconnect: { addFlow.beginReauth(account.id) },
                moveUp: { move(account: account, toGap: index - 1, in: accounts) },
                moveDown: { move(account: account, toGap: index + 2, in: accounts) },
                remove: { accountPrompt.ask(.remove(account.id)) },
                isRaised: hovered == account.id
            ),
            chrome: chrome,
            liftChanged: { translation in carry(account, at: index, of: accounts, by: translation) },
            liftEnded: { translation in drop(account, at: index, of: accounts, after: translation) }
        )
        // The carry. The carried card rides the pointer directly; the cards it displaces step
        // aside with a spring, retargeting whenever the landing changes; the lift itself is a
        // slight scale and a shadow in two layers. Under Reduce Motion nothing travels on its
        // own: the parting and the lift are instant, and only the pointer moves the card.
        .offset(y: isLifted ? 0 : partingOffset(index: index))
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: lift?.gap)
        .offset(y: isLifted ? (lift?.translation ?? 0) : 0)
        .scaleEffect(isLifted && !reduceMotion ? 1.02 : 1)
        .shadow(color: .black.opacity(isLifted ? 0.10 : 0), radius: 1, y: 1)
        .shadow(color: .black.opacity(isLifted ? 0.18 : 0), radius: 14, y: 8)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isLifted)
        .zIndex(isLifted ? 1 : 0)
        .overlay {
            // The keyboard's ring: outside the card, in the accent, only while the keyboard has
            // the panel. Drawn here because the system draws none for arrow-key moves unless
            // Full Keyboard Access is on, and a typist must see where Return will land.
            RoundedRectangle(cornerRadius: PanelMetrics.cardRadius + 3, style: .continuous)
                .inset(by: -3)
                .stroke(
                    Color.accentColor.opacity(keyboardFocusVisible && focusedCard == account.id ? 0.9 : 0),
                    lineWidth: 3
                )
                .accessibilityHidden(true)
        }
        .onHover { inside in
            hovered = inside ? account.id : (hovered == account.id ? nil : hovered)
            if inside { keyboardFocusVisible = false }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focusedCard, equals: account.id)
        .onMoveCommand { direction in
            // The first arrow shows the ring where focus already is; the next ones move it.
            guard keyboardFocusVisible else {
                keyboardFocusVisible = true
                return
            }
            switch direction {
            case .down:
                if index + 1 < accounts.count { focusedCard = accounts[index + 1].id }
            case .up:
                if index > 0 { focusedCard = accounts[index - 1].id }
            default:
                break
            }
        }
        .onKeyPress(.return) {
            keyboardFocusVisible = true
            toggle(account.id)
            return .handled
        }
        .onKeyPress(.space) {
            keyboardFocusVisible = true
            toggle(account.id)
            return .handled
        }
    }

    /// Opens one card's instrument, or closes it. One card at a time: the panel is a glance
    /// surface, and two open instruments would push the fleet off the bottom of it.
    ///
    /// The motion is asked for here, at the change, and not by an `.animation` around the cards.
    /// An animation scoped to the card list animates only what the list itself draws: measured on
    /// this Mac, the instrument crossfaded over the whole curve while the glass slab jumped to its
    /// new height in a single frame, because the views that size the slab — the scroll view, the
    /// panel's content, the fixed-size frame the glass is shaped to — are all above that scope.
    /// A transaction reaches them, so the slab travels with the cards and the panel opens and
    /// closes as one motion. Under Reduce Motion the transaction carries no animation, and the
    /// panel arrives at its new height at once with the instrument dissolving into it.
    private func toggle(_ id: AccountID) {
        withAnimation(PanelMotion.card(reduceMotion: reduceMotion)) {
            expanded = expanded == id ? nil : id
        }
        AccessibilityAnnouncer.layoutChanged()
    }

    /// The question the panel is asking, drawn in the panel's own window.
    ///
    /// Both answers stay open when they are refused. The prompt is the only surface left that can
    /// say why, and closing it would report a change that never reached the device.
    @ViewBuilder private func promptContent(_ account: AccountConfig) -> some View {
        switch accountPrompt.prompt {
        case .rename?:
            RenamePrompt(
                account: account,
                blockedReason: nil,
                refusalReason: accountPrompt.refusalReason,
                // The answer goes through `recordPromptAnswer`, which both records it and says it.
                save: { name in
                    recordPromptAnswer(
                        renameAccount(account, to: name).map(AccountPromptRefusal.rename),
                        in: accountPrompt
                    )
                },
                cancel: { accountPrompt.clear() }
            )
            .id(account.id)
        case .remove?:
            RemoveConfirmation(
                account: account,
                refusalReason: accountPrompt.refusalReason,
                remove: {
                    recordPromptAnswer(
                        addFlow.removeAccount(account.id).map(AccountPromptRefusal.removal),
                        in: accountPrompt
                    )
                },
                cancel: { accountPrompt.clear() }
            )
        case nil:
            EmptyView()
        }
    }

    private var presentedAccounts: [AccountConfig] {
        projectedVisibleAccounts(catalog.accounts, using: visibility)
    }

    /// Renames one account, then asks the catalog what its answer was.
    ///
    /// Reading the name back is the whole point: the catalog can decline the write because it
    /// could not read itself, and a panel that assumed success would close the prompt and
    /// announce a rename that did not happen. Not `@discardableResult`: a caller that drops this
    /// answer does not compile.
    func renameAccount(_ account: AccountConfig, to name: String) -> AccountRenameRefusal? {
        catalog.rename(account.id, to: name)

        let requested = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard catalog.accounts.contains(where: { $0.id == account.id && $0.name == requested })
        else {
            return catalog.loadState == .unreadable ? .accountListUnreadable : .renameWasNotApplied
        }
        return nil
    }

    // MARK: The carry

    /// The pointer has moved the card: remember how far, and work out where it would land.
    private func carry(_ account: AccountConfig, at index: Int, of accounts: [AccountConfig], by translation: CGFloat) {
        let heights = accounts.map { rowHeights[$0.id] ?? 0 }
        let gap = liftedGap(
            from: index,
            translation: Double(translation),
            heights: heights,
            gap: Double(PanelMetrics.cardGap)
        )
        lift = Lift(id: account.id, index: index, translation: translation, gap: gap)
    }

    /// The pointer let go. The card settles into the slot it was over — or, if it never left
    /// its own, springs back — and the catalog's order becomes the panel's, so the strip follows.
    private func drop(_ account: AccountConfig, at index: Int, of accounts: [AccountConfig], after translation: CGFloat) {
        guard let lift, lift.id == account.id else { return }
        let current = accounts.map(\.id)
        let reordered = reorderedIDs(current, moving: account.id, toGap: lift.gap)
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            self.lift = nil
            if reordered != current {
                commitVisibleReorder(reordered, movedAccount: account)
            }
        }
    }

    /// How far a resting card steps aside for the carried one: the carried card's height plus
    /// the gap, up or down, when it sits between the carried card's own slot and the one it
    /// would take.
    private func partingOffset(index: Int) -> CGFloat {
        guard let lift, let carried = rowHeights[lift.id] else { return 0 }
        let target = lift.gap > lift.index ? lift.gap - 1 : lift.gap
        let step = CGFloat(carried) + PanelMetrics.cardGap
        if target > lift.index, index > lift.index, index <= target { return -step }
        if target < lift.index, index >= target, index < lift.index { return step }
        return 0
    }

    private func move(account: AccountConfig, toGap gap: Int, in accounts: [AccountConfig]) {
        let current = accounts.map(\.id)
        let reordered = reorderedIDs(current, moving: account.id, toGap: gap)
        guard reordered != current else { return }
        _ = commitVisibleReorder(reordered, movedAccount: account)
    }

    @discardableResult
    func commitVisibleReorder(
        _ orderedVisibleIDs: [AccountID],
        movedAccount: AccountConfig
    ) -> Bool {
        let fullOrder = catalogOrder(replacingVisibleSlotsWith: orderedVisibleIDs)
        if reduceMotion {
            catalog.reorder(fullOrder)
        } else {
            withAnimation(.smooth(duration: 0.3)) { catalog.reorder(fullOrder) }
        }

        guard let position = orderedVisibleIDs.firstIndex(of: movedAccount.id) else { return true }
        AccessibilityAnnouncer.announce(
            qfLocalized(
                "announce.moved",
                defaultValue: "Moved \(movedAccount.name) to position \(position + 1) of \(orderedVisibleIDs.count)",
                comment: "VoiceOver announcement after account reorder."
            )
        )
        return true
    }

    private func catalogOrder(
        replacingVisibleSlotsWith orderedVisibleIDs: [AccountID]
    ) -> [AccountID] {
        var reorderedVisible = orderedVisibleIDs.makeIterator()
        return catalog.accounts.map { account in
            guard visibility.isVisible(account.id) else { return account.id }
            return reorderedVisible.next() ?? account.id
        }
    }
}
