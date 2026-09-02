import AppKit
import QotaFolioCore
import QotaFolioKit

@MainActor
final class ProductionSettingsRoute {
    private var presenter: SettingsWindowPresenter?

    lazy var openSettings: OpenSettings = { [weak self] in
        self?.presenter?.present()
    }

    func install(_ presenter: SettingsWindowPresenter) {
        precondition(self.presenter == nil, "The production Settings presenter was installed twice.")
        self.presenter = presenter
    }
}

@MainActor
final class ProductionStatusMenuController: NSObject, NSMenuItemValidation {
    let menu: NSMenu

    private let updater: any SettingsUpdating
    private let store: any AccountsStoring
    private let privacy: ScreenPrivacy
    private let openSettings: OpenSettings

    init(
        updater: any SettingsUpdating,
        store: any AccountsStoring,
        privacy: ScreenPrivacy,
        openSettings: @escaping OpenSettings
    ) {
        self.updater = updater
        self.store = store
        self.privacy = privacy
        self.openSettings = openSettings
        self.menu = NSMenu()
        super.init()

        let refresh = NSMenuItem(
            title: "Refresh Now",
            action: #selector(refreshNow(_:)),
            keyEquivalent: "r"
        )
        refresh.target = self

        let hideNames = NSMenuItem(
            title: qfLocalized("settings.privacy.hideNames", defaultValue: "Hide account names", comment: "Switch that hides account names on the panel and in the strip's words."),
            action: #selector(toggleHideNames(_:)),
            keyEquivalent: ""
        )
        hideNames.target = self

        let check = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        check.target = self

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsItem(_:)),
            keyEquivalent: ","
        )
        settings.target = self

        let quit = NSMenuItem(
            title: "Quit QotaFolio",
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quit.target = self

        menu.items = [
            refresh,
            .separator(),
            hideNames,
            .separator(),
            check,
            settings,
            .separator(),
            quit,
        ]
        menu.autoenablesItems = true
    }

    @objc private func refreshNow(_ sender: NSMenuItem) {
        store.requestRefreshAll()
    }

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        updater.checkForUpdates()
    }

    /// The person's own blanket, from the bar: the same flag Settings → Privacy sets.
    @objc private func toggleHideNames(_ sender: NSMenuItem) {
        privacy.namesHiddenByHand.toggle()
    }

    @objc private func openSettingsItem(_ sender: NSMenuItem) {
        openSettings()
    }

    /// The status menu's Quit takes the same deferred route as every other user-facing Quit.
    ///
    /// `NSApp.terminate` answers `applicationShouldTerminate`, which replies `.terminateLater`
    /// and spins a nested run loop until the reply arrives. The reply is produced by a
    /// MainActor task, and every MainActor task body is a main-queue block; libdispatch does
    /// not drain the main queue reentrantly, so a terminate issued from inside one spins a
    /// loop that can never run the task that would end it. AppKit dispatches a menu-item
    /// action after dismissing the menu, which is precisely that position, and the app would
    /// hang in `terminateLater` — unquittable from its own menu.
    @objc private func quitApplication(_ sender: NSMenuItem) {
        requestQotaFolioTermination()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleHideNames(_:)):
            menuItem.state = privacy.namesHiddenByHand ? .on : .off
            return true
        case #selector(checkForUpdates(_:)):
            return updater.updateCheckAvailability == .ready
        case #selector(refreshNow(_:)):
            return usageRefreshAvailability(
                updates: store.usageUpdates,
                manualRefresh: store.manualRefresh,
                hasRefreshableAccount: !store.pollStatus.isEmpty
            ) == .available
        default:
            return true
        }
    }
}
