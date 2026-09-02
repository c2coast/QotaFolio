import Observation
import SwiftUI
import QotaFolioCore

/// Whether the Settings window shows the add-account flow itself.
///
/// Settings hides the menu-bar panel when it opens, so a flow started from
/// Settings has no other surface left to render on. Settings therefore presents
/// the flow, and it presents a flow that was started anywhere else for the same
/// reason: the panel that was showing it is gone.
///
/// One modal surface owns the window at a time. The uninstall surface takes the
/// window whenever it is not idle, so the flow is never stacked on a removal
/// confirmation, and a removal that is already running never has an add-account
/// sheet appear over it.
public nonisolated func settingsPresentsAddFlow(
    _ flow: AccountFlowPhase?,
    uninstallState: UninstallPresentationState
) -> Bool {
    guard uninstallState == .idle else { return false }
    return renderableFlow(flow) != nil
}

/// Whether the **panel** shows the add-account flow, given what Settings is doing with it.
///
/// The same rule as `settingsPresentsAddFlow`, read from the other side, and the two together say
/// the whole thing: **one surface presents the flow at a time, and the Settings sheet is the one
/// that wins.** The sheet is window-modal and exists for exactly as long as it presents the flow;
/// the panel is a glance surface a user opens to read a number. A modal transaction is not
/// displaced by a glance, so the panel yields and goes back to the account list.
///
/// Settings hides the panel when it opens, so most of the time nothing is being arbitrated here.
/// The panel can be opened again afterwards, though, and without this rule that is two live
/// renderings of one flow: two naming steps with two independent text fields, of which only the
/// one whose Continue was pressed is submitted; two countdowns; and the failure a user is already
/// reading announced to them a second time.
///
/// It is not symmetric with the uninstall rule above, and it must not be. The uninstall surface
/// refuses the flow **and** the panel then has it — one surface still shows it. Here the Settings
/// sheet has it, so the panel does not.
public nonisolated func panelPresentsAddFlow(
    _ flow: AccountFlowPhase?,
    settingsIsPresentingAddFlow: Bool
) -> Bool {
    guard !settingsIsPresentingAddFlow else { return false }
    return renderableFlow(flow) != nil
}

/// The Settings window, as the panel has to see it.
///
/// One fact crosses between the app's two surfaces: is the add-account flow on screen in Settings
/// right now. The panel needs it twice — to decide whether to present the flow itself, and to
/// decide whether its own dismissal retires a terminal failure. `Observable`, because a SwiftUI
/// body reads it: the panel re-renders when the answer changes, and a plain Bool read inside
/// `body` would leave the panel drawing an answer that stopped being true.
@MainActor public protocol SettingsAddFlowPresenting: AnyObject, Observable {
    /// True while the Settings window has the add-account flow on screen.
    var settingsIsPresentingAddFlow: Bool { get }

    /// Brings the window holding the flow in front of the user.
    ///
    /// The panel calls this instead of showing itself, on the two occasions it would otherwise
    /// show itself: a browser handing the transaction back, and a flow just started. On both,
    /// showing the panel would put quota numbers in front of the sign-in the user is being
    /// returned to.
    ///
    /// The panel takes itself off screen before it calls this, so what arrives in front of the
    /// user is one surface and not two. That is the panel's own decision and not a promise asked
    /// of this method — an implementation here brings its window forward and owes the panel
    /// nothing.
    func bringAddFlowSurfaceForward()
}

/// The add-account flow as the Settings window presents it.
///
/// The same projection the panel renders, sized for a sheet. Every renderable
/// phase carries its own dismissal — Cancel on the live phases, Dismiss on a
/// terminal failure — and each of those is the `.cancelAction`, so Escape closes
/// the sheet through the flow rather than behind its back.
public struct SettingsAddFlowSheet: View {
    private let addFlow: any AddFlowPresenting

    public init(addFlow: any AddFlowPresenting) {
        self.addFlow = addFlow
    }

    public var body: some View {
        AddFlowView(addFlow: addFlow)
            .frame(width: 460)
            // A sheet exists for exactly as long as it is presented, so this rendering being
            // evaluated at all means the user is looking at it. Said out loud rather than left to
            // the environment default: this is one of the flow's two surfaces, and the other one
            // answers here too. A reader who greps for the value finds both suppliers.
            .environment(\.surfaceIsOnScreen, true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(qfLocalized(
                "settings.accounts.addFlow.label",
                defaultValue: "Add account",
                comment: "VoiceOver label for the add-account sheet the Settings window presents."
            ))
            .accessibilityIdentifier(SettingsAXIdentifiers.addFlow)
            .onAppear { AccessibilityAnnouncer.screenChanged() }
    }
}

/// Accessibility identifiers the Settings surface owns.
public nonisolated enum SettingsAXIdentifiers {
    public static let addFlow = "qotafolio.settings.accounts.addFlow"
    public static let launchAtLogin = "qotafolio.settings.launchAtLogin"
    public static let appearance = "qotafolio.settings.appearance"
    public static let stripShows = "qotafolio.settings.stripShows"
    public static let alertsEnabled = "qotafolio.settings.alerts.enabled"
    public static let alertsPermission = "qotafolio.settings.alerts.permission"
    public static let privacyHideNames = "qotafolio.settings.privacy.hideNames"
    public static let privacyHideNamesWhileShared = "qotafolio.settings.privacy.hideNamesWhileShared"
    public static let privacyBlanket = "qotafolio.settings.privacy.blanket"
    public static let privacyLeaves = "qotafolio.settings.privacy.leaves"
    public static func accountActions(_ id: AccountID) -> String {
        "qotafolio.settings.account.\(id.rawValue.uuidString.lowercased()).actions"
    }
}
