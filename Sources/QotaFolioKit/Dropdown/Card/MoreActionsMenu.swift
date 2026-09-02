import SwiftUI
import QotaFolioCore

public struct MoreActionsMenu: View {
    public let account: AccountConfig
    public let canMoveUp: Bool
    public let canMoveDown: Bool
    public let mutationBlocked: Bool
    /// Why every mutating item is dimmed, when something outside this menu decided it.
    ///
    /// A dimmed menu item announces itself as "dimmed" and nothing more, so the reason has to
    /// travel with it. It becomes the menu's help text and its accessibility hint, which is
    /// where a pointer user and a VoiceOver user each look for it.
    public let blockedReason: String?
    public let flowBlocked: Bool
    public let rename: () -> Void
    /// Starts the sign-in again and answers with the reason it did not, if it did not.
    ///
    /// Typed rather than `() -> Void` on purpose. A `Void` closure around a call that answers is
    /// where a refusal goes to die: the compiler accepts a single-expression closure whose result
    /// it discards, so the one thing warnings-as-errors is protecting here would be lost at the
    /// call site rather than caught at it.
    public let reconnect: () -> AccountReconnectRefusal?
    public let moveUp: () -> Void
    public let moveDown: () -> Void
    public let remove: () -> Void
    /// Whether the card this menu belongs to is under the pointer. The `…` is always drawn, so
    /// it is reachable by keyboard; it comes forward on hover without moving anything.
    public let isRaised: Bool

    /// The panel's question-and-answer state, or nil in a build that has no panel.
    /// See `AccountCard.panelQuestions`.
    @Environment(AccountPromptState.self) private var panelQuestions: AccountPromptState?
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hoveredSelf = false

    public init(
        account: AccountConfig,
        canMoveUp: Bool,
        canMoveDown: Bool,
        mutationBlocked: Bool,
        blockedReason: String?,
        flowBlocked: Bool,
        rename: @escaping () -> Void,
        reconnect: @escaping () -> AccountReconnectRefusal?,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void,
        remove: @escaping () -> Void,
        isRaised: Bool = false
    ) {
        self.account = account
        self.canMoveUp = canMoveUp
        self.canMoveDown = canMoveDown
        self.mutationBlocked = mutationBlocked
        self.blockedReason = blockedReason
        self.flowBlocked = flowBlocked
        self.rename = rename
        self.reconnect = reconnect
        self.moveUp = moveUp
        self.moveDown = moveDown
        self.remove = remove
        self.isRaised = isRaised
    }

    public var body: some View {
        Menu {
            Button(action: rename) {
                Label(
                    qfLocalized("action.rename", defaultValue: "Rename…", comment: "Rename an account."),
                    systemImage: "pencil"
                )
            }
            .disabled(mutationBlocked)

            Button {
                // The menu closes on the press, so the answer cannot be shown here. It goes to
                // the panel's own state, which draws it on the card this menu belongs to — the
                // same place the card's own Reconnect button puts it.
                recordReconnectAnswer(reconnect(), for: account.id, in: panelQuestions)
            } label: {
                Label(
                    qfLocalized("action.reconnect", defaultValue: "Reconnect…", comment: "Reconnect an account with the provider."),
                    systemImage: "key.fill"
                )
            }
            .disabled(mutationBlocked || flowBlocked)

            Divider()

            Button(action: moveUp) {
                Label(
                    qfLocalized("action.moveUp", defaultValue: "Move Up", comment: "Move an account earlier in display order."),
                    systemImage: "arrow.up"
                )
            }
            .disabled(mutationBlocked || !canMoveUp)
            .accessibilityIdentifier(AXIdentifiers.accountMoveUp(account.id))

            Button(action: moveDown) {
                Label(
                    qfLocalized("action.moveDown", defaultValue: "Move Down", comment: "Move an account later in display order."),
                    systemImage: "arrow.down"
                )
            }
            .disabled(mutationBlocked || !canMoveDown)
            .accessibilityIdentifier(AXIdentifiers.accountMoveDown(account.id))

            Divider()

            Button(role: .destructive, action: remove) {
                Label(
                    qfLocalized("action.removeAccount", defaultValue: "Remove Account", comment: "Remove one connected account and its saved sign-in."),
                    systemImage: "trash"
                )
            }
            .disabled(mutationBlocked)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isRaised || hoveredSelf ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: PanelMetrics.glyphWell, height: PanelMetrics.glyphWell)
                .background(
                    Color.primary.opacity(hoveredSelf ? PanelChrome.hoverWash(contrast) : 0),
                    in: Circle()
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: PanelMetrics.hitTarget, height: PanelMetrics.hitTarget)
        .contentShape(Rectangle())
        .onHover { hoveredSelf = $0 }
        .animation(.easeOut(duration: 0.15), value: isRaised)
        .animation(.easeOut(duration: 0.15), value: hoveredSelf)
        .help(blockedReason ?? qfLocalized("action.more", defaultValue: "More actions", comment: "Account actions menu help text."))
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(blockedReason ?? "")
        .accessibilityIdentifier(AXIdentifiers.accountMoreActions(account.id))
    }

    /// What VoiceOver says when it reaches this button.
    ///
    /// The account's name is in it. Five of these buttons sit in one list, each opens a menu whose
    /// last item removes an account, and the tree that tells them apart tells them apart by
    /// identifier — which VoiceOver never speaks. Measured in the shipping panel with five
    /// accounts: every one of the five announced "More actions" and nothing else, so a user
    /// arriving at one by rotor or by control navigation could not tell which account they were
    /// about to rename or remove. The tooltip keeps the short wording: a pointer is already on
    /// the row it is asking about.
    var spokenLabel: String {
        qfLocalized(
            "action.more.forAccount",
            defaultValue: "More actions for \(account.name)",
            comment: "VoiceOver label for one account row's actions menu. The placeholder is the account's name."
        )
    }
}
