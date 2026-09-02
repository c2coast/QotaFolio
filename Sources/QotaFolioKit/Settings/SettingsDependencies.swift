import Observation
import SwiftUI
import QotaFolioCore

/// Whether an update check can start right now, and when it cannot, why not.
///
/// A boolean cannot tell the two refusals apart, and the difference is the whole of what a
/// user should see. An updater that never started has no update mechanism behind it at all,
/// which is worth one sentence in Settings. An updater in the middle of a routine background
/// check is working perfectly and will be ready again shortly, which is worth nothing but a
/// disabled button. A single boolean answers both with `false`, so any notice honest enough to
/// explain the first would flash during every scheduled check.
public nonisolated enum UpdateCheckAvailability: Equatable, Sendable {
    /// The updater is not running: Sparkle refused the app's update configuration at launch.
    /// Nothing sits behind the update controls, so the controls are not offered.
    case unavailable
    /// The updater is running and is already busy with a check.
    case busy
    /// The updater is running and idle. A check can start now.
    case ready
}

@MainActor public protocol SettingsUpdating: AnyObject, Observable {
    var updateCheckAvailability: UpdateCheckAvailability { get }
    var automaticallyChecksForUpdates: Bool { get }
    var automaticallyDownloadsUpdates: Bool { get }
    func checksBinding() -> Binding<Bool>
    func downloadsBinding() -> Binding<Bool>
    func checkForUpdates()
}

public nonisolated enum LoginAtStartupStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
}

@MainActor public protocol LoginAtStartupControlling: AnyObject, Observable {
    var status: LoginAtStartupStatus { get }
    var failureMessage: String? { get }

    /// Counts the times the app re-read the system's Open-at-Login registration and
    /// found an answer it did not write.
    ///
    /// The registration is approved or denied in System Settings, outside this app,
    /// so what the app last wrote is not what the toggle should show. A Settings
    /// surface announces on this edge, because the control moved with nobody
    /// touching it.
    var externalStatusChangeCount: Int { get }

    func enabledBinding() -> Binding<Bool>
    func refresh()
    func openLoginItemsSettings()
}

public extension LoginAtStartupControlling {
    /// A controller with no system registration behind it never reconciles.
    var externalStatusChangeCount: Int { 0 }
}

@MainActor public protocol AccountVisibilityControlling: AnyObject, Observable {
    func isVisible(_ accountID: AccountID) -> Bool
    func setVisible(_ visible: Bool, for accountID: AccountID)
    func visibilityBinding(for accountID: AccountID) -> Binding<Bool>
}
