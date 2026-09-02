import SwiftUI
import QotaFolioCore

/// The panel's own chrome, and one fact about the panel itself: when its readings were last
/// updated, then `+`, then the `…` menu that holds Refresh Now, Settings… and Quit — the way
/// Apple's own menu-bar panels keep one entry at the bottom. No sentence about the accounts
/// lives here; the cards say everything there is to say about them.
public struct PanelFooterView: View {
    private let catalog: (any AccountCataloging)?
    private let store: any AccountsStoring
    private let addFlow: (any AddFlowPresenting)?
    private let hasAccount: Bool
    private let showsAddButton: Bool

    @Environment(\.openQotaFolioSettings) private var openSettings
    @Environment(\.sentenceStyle) private var style

    public init(
        catalog: any AccountCataloging,
        store: any AccountsStoring,
        addFlow: any AddFlowPresenting,
        hasAccount: Bool,
        showsAddButton: Bool = true
    ) {
        self.catalog = catalog
        self.store = store
        self.addFlow = addFlow
        self.hasAccount = hasAccount
        self.showsAddButton = showsAddButton
    }

    public init(store: any AccountsStoring, hasAccount: Bool) {
        self.catalog = nil
        self.store = store
        self.addFlow = nil
        self.hasAccount = hasAccount
        self.showsAddButton = false
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let updated = lastUpdated {
                let clock = PanelWords.clock(updated, style: style)
                Text(qfLocalized(
                    "footer.updated",
                    defaultValue: "Updated \(clock)",
                    comment: "Quiet footer note: the clock time of the newest reading across the accounts."
                ))
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .accessibilityLabel(qfLocalized(
                    "footer.updated.ax",
                    defaultValue: "Readings updated at \(clock)",
                    comment: "VoiceOver label for the footer's updated time. The argument is a clock time."
                ))
            }

            Spacer(minLength: 4)

            if showsAddButton, let addFlow {
                PanelChromeButton(
                    symbol: "plus",
                    label: qfLocalized("footer.addAccount", defaultValue: "Add Account…", comment: "Button that opens the add-account flow, in the panel footer and in Settings."),
                    help: addHelp
                ) {
                    addFlow.beginAddFlow()
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(addBlocked)
                .padding(.vertical, -6)
                .accessibilityIdentifier(AXIdentifiers.footerAddAccount)
            }

            moreMenu
        }
        .padding(.leading, PanelMetrics.panelPadding + PanelMetrics.cardPadding)
        // The glyph well sits under the cards' own `…`: the same distance from the edge.
        .padding(.trailing, PanelMetrics.panelPadding + PanelMetrics.cardPadding - (PanelMetrics.hitTarget - PanelMetrics.glyphWell) / 2)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        // Nobody asked for this. The engine closed itself, every quota froze, and the control
        // that looks like it could fix it went dead — so a VoiceOver user is told, in the same
        // sentence the menu carries as its help.
        .onChange(of: store.usageUpdates) { _, current in
            guard store.isPanelVisible,
                  let presentation = UsageUpdatesPresentation.make(current)
            else { return }
            AccessibilityAnnouncer.announce(presentation.reason)
        }
    }

    /// Refresh, Settings and Quit behind one button.
    private var moreMenu: some View {
        Menu {
            Button(refreshLabel) {
                store.requestRefreshAll()
            }
            .keyboardShortcut("r", modifiers: .command)
            // One decision, taken once. `requestRefreshAll` returns without doing anything once
            // the engine has closed itself, and it says nothing when it does.
            .disabled(refreshAvailability != .available)
            .accessibilityIdentifier(AXIdentifiers.footerRefresh)

            Divider()

            Button(qfLocalized("footer.settings", defaultValue: "Settings…", comment: "Footer menu item that opens QotaFolio Settings.")) {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityIdentifier(AXIdentifiers.footerSettings)

            Divider()

            Button(qfLocalized("footer.quit", defaultValue: "Quit QotaFolio", comment: "Button that quits QotaFolio, in the panel footer and on the screen shown when the account list cannot be read.")) {
                requestQotaFolioTermination()
            }
            .keyboardShortcut("q", modifiers: .command)
            .accessibilityIdentifier(AXIdentifiers.footerQuit)
        } label: {
            PanelChromeGlyph(symbol: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: PanelMetrics.hitTarget, height: PanelMetrics.hitTarget)
        .contentShape(Rectangle())
        .padding(.vertical, -6)
        // The tooltip says why refreshing is dead when it is dead; VoiceOver reads the same
        // words as the element's help.
        .help(moreHelp)
        .accessibilityLabel(qfLocalized("footer.more.ax", defaultValue: "More: Refresh, Settings, Quit", comment: "VoiceOver label for the footer's actions menu."))
        .accessibilityIdentifier(AXIdentifiers.footerMore)
    }

    /// The newest reading across the accounts, or nil before the first.
    private var lastUpdated: Date? {
        store.snapshots.values.map(\.fetchedAt).max()
    }

    private var isRefreshing: Bool {
        if case .some(.inProgress) = store.manualRefresh { return true }
        return false
    }

    private var refreshAvailability: UsageRefreshAvailability {
        usageRefreshAvailability(
            updates: store.usageUpdates,
            manualRefresh: store.manualRefresh,
            hasRefreshableAccount: hasAccount
        )
    }

    private var moreHelp: String {
        if let reason = updatesHaltedReason { return reason }
        return qfLocalized("footer.more.help", defaultValue: "Refresh, Settings, Quit", comment: "Tooltip for the footer's actions menu.")
    }

    private var updatesHaltedReason: String? {
        guard refreshAvailability == .halted else { return nil }
        return UsageUpdatesPresentation.make(store.usageUpdates)?.reason
    }

    /// The item describes the work, not the affordance.
    private var refreshLabel: String {
        if isRefreshing {
            return qfLocalized("footer.refresh.busy", defaultValue: "Refreshing…", comment: "Refresh menu item while a manual refresh is in flight.")
        }
        return qfLocalized("footer.refreshNow", defaultValue: "Refresh Now", comment: "Footer menu item that refreshes every account.")
    }

    private var addBlocked: Bool {
        guard let catalog, let addFlow else { return false }
        return renderableFlow(addFlow.activeFlow) != nil
            || occupancy(
                accountCount: catalog.accounts.count,
                pendingReservationCount: catalog.pendingReservationCount
            ) >= qotaFolioMaximumAccounts
            || catalog.loadState == .unreadable
    }

    private var addHelp: String {
        if let catalog,
           occupancy(
               accountCount: catalog.accounts.count,
               pendingReservationCount: catalog.pendingReservationCount
           ) >= qotaFolioMaximumAccounts {
            return qfLocalized(
                "footer.addAccount.atCap",
                defaultValue: "Remove an account before adding another.",
                comment: "Tooltip on Add Account when all slots are occupied."
            )
        }
        return qfLocalized("footer.tooltip.addAccount", defaultValue: "Add an account (⌘N)", comment: "Tooltip for starting the add-account flow.")
    }
}

/// One of the panel's own actions: a 13 pt symbol in a 28 pt well inside a 40 pt hit target, a
/// wash under the pointer, a quiet press.
struct PanelChromeButton: View {
    let symbol: String
    let label: String
    let help: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: PanelMetrics.glyphWell, height: PanelMetrics.glyphWell)
        }
        .buttonStyle(PanelChromeButtonStyle())
        .help(help)
        .accessibilityLabel(label)
    }
}

/// The footer menu's face: the same well and wash as the buttons beside it.
private struct PanelChromeGlyph: View {
    let symbol: String

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: PanelMetrics.glyphWell, height: PanelMetrics.glyphWell)
            .background(
                Color.primary.opacity(hovered ? PanelChrome.hoverWash(contrast) : 0),
                in: Circle()
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.15), value: hovered)
            .onHover { hovered = $0 }
    }
}

/// The panel's control style: secondary ink, a circular wash on hover, 0.96 on press, dimmed
/// when disabled. Hit target 40 pt whatever the glyph.
struct PanelChromeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelChromeButtonBody(configuration: configuration)
    }
}

/// The style's body, a view of its own so the hover state has somewhere to live.
private struct PanelChromeButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
            .background(
                Color.primary.opacity(hovered && isEnabled ? PanelChrome.hoverWash(contrast) : 0),
                in: Circle()
            )
            .frame(width: PanelMetrics.hitTarget, height: PanelMetrics.hitTarget)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovered = $0 }
    }
}
