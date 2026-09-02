import AppKit
import Foundation
import Sparkle
import QotaFolioCore
import QotaFolioKit

@MainActor
final class ProductionAppRuntime: AppRuntime {
    private let log: ProductionRedactingLogger
    private let transport: CancellableURLSessionTransport
    private let endpointGuard: ProviderEndpointGuard
    private let providerEnvironment: ProviderEnvironment
    private let providerSuites: [AccountProvider: ProviderSuite]

    private let catalogStore: FileCatalogStore
    private let catalog: AccountCatalog
    private let keychainStore: KeychainTokenStore
    private let vault: QotaFolioTokenVault

    private let pollingSystem: ProductionUsagePollingSystem
    private let store: AccountsStore
    private let accountLifecycle: AccountLifecycleCoordinator

    private let visibility: PersistedAccountVisibilityController
    private let scheduler: AppCandidacyScheduler

    private let updaterDelegate: ProductionSparkleUpdateDelegate
    private let updaterController: SPUStandardUpdaterController
    private let updaterSource: ProductionSparkleControllerSource
    private let updater: SparkleSettingsAdapter
    private let launchAtLogin: SMAppServiceLoginAtStartupAdapter

    private let privacy: ScreenPrivacy
    private let alertPreferences: AlertPreferences
    private let alerts: AlertDeliverer
    private let surfaceRelay: SurfaceRelay
    private let settingsRoute: ProductionSettingsRoute
    private let statusMenu: ProductionStatusMenuController
    private let statusSurface: AppKitStatusItemSurface
    private let statusItem: StatusItemController
    private let panelController: any PanelToggling
    private let uninstall: Uninstall
    private let settingsPresenter: SettingsWindowPresenter

    private var started = false

    static func make() async throws -> ProductionAppRuntime {
        let log = ProductionRedactingLogger()
        let transport = CancellableURLSessionTransport()
        // Every provider request goes through here. Nothing addressed anywhere but the endpoints
        // named in `ProviderTransportEndpoint` reaches the network, and the guard says so out
        // loud when it refuses one.
        let endpointGuard = ProviderEndpointGuard(underlying: transport, log: log)
        let now: @Sendable () -> Date = { Date() }
        let monotonic = SystemMonotonicClock()
        let browser = WorkspaceBrowserOpener()
        let providerEnvironment = ProviderRegistry.productionEnvironment(
            transport: endpointGuard,
            appVersion: appVersion(),
            now: now,
            log: log,
            clock: monotonic,
            browser: browser
        )

        // Before anything opens a file. A user updating from a build that kept its files
        // inside its own sandbox container has accounts and a week of samples sitting where
        // this build no longer looks; this is the launch that moves them. It is a no-op on
        // every launch after the first, and on a fresh install it is a no-op for ever.
        let migration = SharedContainerMigration.runIfNeeded()
        if migration.ran {
            log.emit(
                DiagEvent(
                    provider: nil,
                    operation: .containerMigrate,
                    outcome: migration.failed ? .permanent : .ok,
                    sizeBucket: migration.adopted.count,
                    machineErrorCode: migration.refused.isEmpty ? nil : "refused"
                )
            )
        }

        let catalogStore = FileCatalogStore(url: try FileCatalogStore.defaultURL())
        let catalog = AccountCatalog(store: catalogStore, log: log)
        let keychainStore = KeychainTokenStore()
        let vault = QotaFolioTokenVault(
            itemStore: keychainStore,
            refreshDecoders: [
                .anthropic: AnthropicRefreshResponseDecoder(),
                .openai: OpenAIRefreshResponseDecoder(),
            ],
            transport: endpointGuard,
            now: now,
            sink: catalog,
            log: log,
            // Disconnect ends the grant at Anthropic as well as here. This is the whole of that
            // wire: the vault holds the refresh token, so the vault is what revokes. ChatGPT has
            // no public revocation endpoint, so it has no entry, and the dictionary says that
            // without anyone writing a branch.
            revokers: [
                .anthropic: AnthropicRevokeClient(
                    transport: endpointGuard,
                    clock: monotonic,
                    log: log
                ),
            ]
        )

        catalog.load()
        let records = reconcileRecords(from: catalog.accounts)
        let scan = await vault.scanStoredCredentials()
        let startupReauthenticated = await applyStartupReconciliation(
            catalog: catalog,
            vault: vault,
            records: records,
            scan: scan
        )

        let providerSuites = Dictionary(
            uniqueKeysWithValues: AccountProvider.allCases.map { provider in
                (provider, ProviderRegistry.suite(for: provider, environment: providerEnvironment))
            }
        )
        let usageProviders = providerSuites.mapValues(\.usage)
        let pollingSystem = ProductionUsagePollingSystem(
            clock: ContinuousPollClock(),
            vault: vault,
            providers: usageProviders,
            activityLease: AppNapLease()
        )
        let store = pollingSystem.store
        store.reconcile(
            accounts: catalog.accounts,
            reauthenticated: startupReauthenticated
        )

        let accountLifecycle = AccountLifecycleCoordinator(
            catalog: catalog,
            store: store,
            vault: vault,
            providerSuites: providerSuites,
            browser: browser,
            monotonic: monotonic,
            log: log,
            makeIdentitySource: { provider in
                ProviderIdentitySource.make(
                    provider: provider,
                    environment: providerEnvironment
                )
            }
        )

        let visibility = PersistedAccountVisibilityController(catalog: catalog)
        let scheduler = AppCandidacyScheduler()

        // The panel's global shortcut: ⌃⌥Q until the person records another. What it fires is
        // installed with the status item below.
        let panelShortcut = GlobalShortcutStore()

        let updaterDelegate = ProductionSparkleUpdateDelegate()
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )
        let updaterSource = ProductionSparkleControllerSource(
            controller: updaterController,
            log: log
        )
        let updater = SparkleSettingsAdapter(source: updaterSource)
        let launchAtLogin = SMAppServiceLoginAtStartupAdapter()

        // The privacy blanket and the alerts. Both keep their preferences in the app's own
        // defaults domain, beside the account visibility.
        let privacy = ScreenPrivacy()
        let alertPreferences = AlertPreferences()
        // Which appearance QotaFolio's own windows wear. Not the application's: the menu-bar
        // batteries follow the bar they sit in, and `AppearancePreferences` says why.
        let appearancePreferences = AppearancePreferences()
        // Which quantity the menu-bar batteries are drawn to: what this session lets you spend,
        // or what the week still holds. The strip and the Control both follow it.
        let stripPreferences = StripPreferences()
        let alerts = AlertDeliverer(
            store: store,
            preferences: alertPreferences,
            center: UserNotificationAlertCenter()
        )

        // The Control and the widget follow the app through this: the blanket and the hidden
        // set mirrored into the group defaults, and a reload when — and only when — what a
        // surface renders has changed.
        let surfaceRelay = SurfaceRelay(
            catalog: catalog,
            store: store,
            visibility: visibility,
            privacy: privacy,
            stripShows: stripPreferences,
            drainCatalog: { [weak catalog] in await catalog?.drainPendingCommits() }
        )

        let settingsRoute = ProductionSettingsRoute()
        let statusMenu = ProductionStatusMenuController(
            updater: updater,
            store: store,
            privacy: privacy,
            openSettings: settingsRoute.openSettings
        )
        let statusSurface = AppKitStatusItemSurface(rightClickMenu: statusMenu.menu)
        let statusItem = StatusItemController(
            catalog: catalog,
            store: store,
            visibility: visibility,
            scheduler: scheduler,
            surface: statusSurface,
            privacy: privacy,
            stripShows: stripPreferences
        )
        let panelController = MenuBarPanelController(
            catalog: catalog,
            store: store,
            addFlow: accountLifecycle,
            onPanelShown: { [weak statusItem] in
                statusItem?.panelDidBecomeVisible()
            },
            openSettings: settingsRoute.openSettings,
            content: { [weak statusItem] catalog, store, addFlow in
                PanelContentView(
                    catalog: catalog,
                    store: store,
                    addFlow: addFlow,
                    visibility: visibility,
                    privacy: privacy,
                    menuBarPlacement: { statusItem?.menuBarPlacement ?? .placed }
                )
            }
        )
        statusItem.panel = panelController

        // Spotlight's and the Control's road into the running app: `OpenQotaFolioIntent`
        // performs in this process, and this is how it reaches the panel. The status item is
        // captured weakly — an intent that arrives during termination finds nothing and shows
        // nothing, which is the right answer for an app on its way out.
        QotaFolioIntentRuntime.install(revealPanel: { [weak statusItem] in
            statusItem?.showPanel()
        })
        IntentServices.install(store: store, catalog: catalog, privacy: privacy, stripShows: stripPreferences)
        // The keyboard's own click on the batteries, from any app.
        panelShortcut.activate { [weak statusItem] in
            statusItem?.togglePanel()
        }

        panelController.dismissalMonitor.escapeHandler = { [weak accountLifecycle] in
            guard let accountLifecycle else { return false }
            switch accountLifecycle.activeFlow {
            case .some(.failed):
                accountLifecycle.acknowledgeFailure()
                return true
            case .some:
                accountLifecycle.cancelActiveFlow(.escape)
                return true
            case nil:
                return false
            }
        }

        let uninstall = Uninstall(
            // The vault, not the Keychain store under it. "Remove My Data" ends the grants it
            // deletes, and the refresh token that ends one never leaves the vault -- so the vault
            // is what does it, with the same `revokers` dictionary Disconnect already uses.
            credentials: vault,
            surroundings: UninstallSurroundings(
                stopPolling: { _ = await pollingSystem.stopAndDrain() },
                removeStatusItem: { statusItem.clearSavedStateAndRemove() },
                quit: { requestApplicationTermination() }
            )
        )

        let settingsPresenter = SettingsWindowPresenter(
            updater: updater,
            launchAtLogin: launchAtLogin,
            catalog: catalog,
            addFlow: accountLifecycle,
            visibility: visibility,
            uninstall: uninstall,
            alertPreferences: alertPreferences,
            alerts: alerts,
            privacy: privacy,
            panelShortcut: panelShortcut,
            appearance: appearancePreferences,
            stripShows: stripPreferences
        )
        panelController.appearanceSource = { [weak appearancePreferences] in
            appearancePreferences?.nsAppearance
        }
        settingsPresenter.panel = panelController
        settingsRoute.install(settingsPresenter)

        return ProductionAppRuntime(
            log: log,
            transport: transport,
            endpointGuard: endpointGuard,
            providerEnvironment: providerEnvironment,
            providerSuites: providerSuites,
            catalogStore: catalogStore,
            catalog: catalog,
            keychainStore: keychainStore,
            vault: vault,
            pollingSystem: pollingSystem,
            store: store,
            accountLifecycle: accountLifecycle,
            visibility: visibility,
            scheduler: scheduler,
            updaterDelegate: updaterDelegate,
            updaterController: updaterController,
            updaterSource: updaterSource,
            updater: updater,
            launchAtLogin: launchAtLogin,
            privacy: privacy,
            alertPreferences: alertPreferences,
            alerts: alerts,
            surfaceRelay: surfaceRelay,
            settingsRoute: settingsRoute,
            statusMenu: statusMenu,
            statusSurface: statusSurface,
            statusItem: statusItem,
            panelController: panelController,
            uninstall: uninstall,
            settingsPresenter: settingsPresenter
        )
    }

    private init(
        log: ProductionRedactingLogger,
        transport: CancellableURLSessionTransport,
        endpointGuard: ProviderEndpointGuard,
        providerEnvironment: ProviderEnvironment,
        providerSuites: [AccountProvider: ProviderSuite],
        catalogStore: FileCatalogStore,
        catalog: AccountCatalog,
        keychainStore: KeychainTokenStore,
        vault: QotaFolioTokenVault,
        pollingSystem: ProductionUsagePollingSystem,
        store: AccountsStore,
        accountLifecycle: AccountLifecycleCoordinator,
        visibility: PersistedAccountVisibilityController,
        scheduler: AppCandidacyScheduler,
        updaterDelegate: ProductionSparkleUpdateDelegate,
        updaterController: SPUStandardUpdaterController,
        updaterSource: ProductionSparkleControllerSource,
        updater: SparkleSettingsAdapter,
        launchAtLogin: SMAppServiceLoginAtStartupAdapter,
        privacy: ScreenPrivacy,
        alertPreferences: AlertPreferences,
        alerts: AlertDeliverer,
        surfaceRelay: SurfaceRelay,
        settingsRoute: ProductionSettingsRoute,
        statusMenu: ProductionStatusMenuController,
        statusSurface: AppKitStatusItemSurface,
        statusItem: StatusItemController,
        panelController: any PanelToggling,
        uninstall: Uninstall,
        settingsPresenter: SettingsWindowPresenter
    ) {
        self.log = log
        self.transport = transport
        self.endpointGuard = endpointGuard
        self.providerEnvironment = providerEnvironment
        self.providerSuites = providerSuites
        self.catalogStore = catalogStore
        self.catalog = catalog
        self.keychainStore = keychainStore
        self.vault = vault
        self.pollingSystem = pollingSystem
        self.store = store
        self.accountLifecycle = accountLifecycle
        self.visibility = visibility
        self.scheduler = scheduler
        self.updaterDelegate = updaterDelegate
        self.updaterController = updaterController
        self.updaterSource = updaterSource
        self.updater = updater
        self.launchAtLogin = launchAtLogin
        self.privacy = privacy
        self.alertPreferences = alertPreferences
        self.alerts = alerts
        self.surfaceRelay = surfaceRelay
        self.settingsRoute = settingsRoute
        self.statusMenu = statusMenu
        self.statusSurface = statusSurface
        self.statusItem = statusItem
        self.panelController = panelController
        self.uninstall = uninstall
        self.settingsPresenter = settingsPresenter
    }

    /// The one thing a quit waits for.
    ///
    /// `Uninstall` is between deleting the Keychain items and its own finished screen for a few
    /// seconds at most -- every step it runs carries its own deadline, including the single wait
    /// on the grant revokes at the end. Quitting inside that window would leave the removal
    /// half-done with no way back, so the quit is asked to come again -- and it does, because the
    /// removal ends on its own and puts a Quit button in front of the user.
    var ordinaryTerminationIsAllowed: Bool { !uninstall.isRemoving }

    func start() {
        guard !started else { return }
        started = true
        updaterSource.start()
        store.start()
        // The blanket watches for a shared screen from here on; the deliverer watches the
        // assessment and asks the system for permission only when an alert is first due; the
        // relay keeps the Control and the widget in step with all of it.
        privacy.start()
        alerts.start()
        surfaceRelay.start()
    }

    /// Puts the panel in front of a user who asked for an app that is already running.
    ///
    /// This runtime's surface is the panel, and the panel hangs from the status item — so the
    /// reveal goes through the status item rather than the panel controller, which would need
    /// an anchor button this runtime does not hold. `showPanel()` answers nothing once the
    /// status item has been removed, which is the right answer after a quit or an uninstall:
    /// a panel with nothing to hang from is not a surface anyone asked for.
    func revealPrimarySurface() {
        guard started else { return }
        statusItem.showPanel()
    }

    /// How long the whole quit waits for the writers that are still running.
    ///
    /// A quit waits for three drains that three different parts of the app own, and each of them
    /// can be changed by someone who is not looking at this function. The budget lives here
    /// because the quit is what spends it: `applicationShouldTerminate` has already answered
    /// `.terminateLater`, and AppKit spins a nested run loop until the reply arrives — so one
    /// unbounded await anywhere below leaves the user with an app that cannot be closed except
    /// through Force Quit. Five seconds is many times a healthy drain of any of the three.
    private static let terminationBudget: Duration = .seconds(5)

    /// The quit, in the order the three authorities need — and the one thing it will not do.
    ///
    /// Account changes close first and their writers get their wait, because a removal whose
    /// credential delete is still in flight is a credential still on the Mac after the user asked
    /// for it to go. Polling stops next, then the catalog's commit chain is flushed, then the
    /// surfaces come down.
    ///
    /// **Nothing here can refuse the quit.** A drain that does not finish inside the budget costs
    /// at worst a rotated refresh token that reached the provider and not the Keychain, or an
    /// authorization state that reverts to the last one written; the next launch gets a 401 or
    /// repairs the row, and asks the user to reconnect if it has to. An app that will not quit is
    /// worse than either.
    func beginOrdinaryTermination() async {
        guard started else { return }
        started = false
        privacy.stop()
        surfaceRelay.stop()

        let writers = Task { @MainActor [self] in
            await accountLifecycle.beginOrdinaryShutdown()
            panelController.hide(reason: .termination)
            _ = await pollingSystem.stopAndDrain()
            // After the stop, so nothing is still arriving, and inside the same budget as every
            // other drain: a quit that waits on a disk is still a quit that waits.
            await pollingSystem.flushHistory()
            await catalog.drainPendingCommits()
        }
        if await awaitWithinTerminationDeadline(
            Self.terminationBudget,
            { await writers.value }
        ) == nil {
            log.emit(
                DiagEvent(
                    provider: nil,
                    operation: .quiesce,
                    outcome: .transient,
                    machineErrorCode: "termination.drain.unfinished"
                )
            )
        }

        visibility.cancelObservation()
        updater.cancelObservation()
        statusItem.remove()
    }

    private static func appVersion(bundle: Bundle = .main) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "0"
    }

    static func reconcileRecords(
        from accounts: [AccountConfig]
    ) -> [CredentialReconcileRecord] {
        accounts.map { account in
            let failedRevision: CredentialRevision? = if case .needsReauthentication(let revision) = account.authorizationState {
                revision
            } else {
                nil
            }
            return CredentialReconcileRecord(
                reference: account.credentialReference,
                accountID: account.id,
                provider: account.provider,
                failedRevision: failedRevision
            )
        }
    }

    /// Startup credential reconciliation, and the one rule that makes it safe to run: this launch
    /// may repair the credential store only if this launch could read it.
    ///
    /// `scanStoredCredentials()` returns an enum, not a set, so that "the store could not be
    /// enumerated" is never mistaken for "nothing is unreferenced". The gate below is the first
    /// half of that rule and it belongs here, in the root: `.unavailable` calls no `reconcile(_:)`
    /// at all, so this launch deletes nothing and writes no authorization state derived from a
    /// store it never read. `reconcile`'s own availability abort cannot stand in for this gate,
    /// because a second enumeration can succeed after the root's scan failed — and a deletion
    /// decided by that second read would be exactly the conflation the enum exists to forbid.
    ///
    /// The second half is the outcome, and `reconcile(_:)` states it. A bare map cannot: its
    /// emptiness means both "I finished and there was nothing to repair" and "I stopped because
    /// the store would not answer", and the difference cannot be re-derived by enumerating the
    /// store again — a pass that aborts on a READ while enumeration still works and leaves no
    /// orphan behind looks exactly like a clean pass, the locked-Keychain-with-a-tidy-store case,
    /// in which the user would be told everything was fine while nothing had been checked.
    /// `CredentialReconcileOutcome` carries the verdict, so the switch below reads the fact
    /// instead of deriving it, and a consumer that forgets an abort does not compile. The advisory
    /// is published only AFTER the pass, and never before: silence is the one disposition that is
    /// definitely wrong here.
    static func applyStartupReconciliation(
        catalog: any AccountCataloging,
        vault: any TokenVaultMaintenance,
        records: [CredentialReconcileRecord],
        scan: StoredCredentialScan
    ) async -> [AccountID: CredentialRevision] {
        switch (catalog.loadState, scan) {
        case (.missing, .unavailable),
             (.unreadable, .unavailable),
             (.loaded, .unavailable):
            catalog.setRecoveryAdvisory(.credentialStoreUnreachable)
            return [:]

        case (.missing, .enumerated(let stored)),
             (.unreadable, .enumerated(let stored)):
            let referenced = Set(records.map(\.reference))
            let unreferenced = stored.subtracting(referenced)
            catalog.setRecoveryAdvisory(
                unreferenced.isEmpty
                    ? nil
                    : .credentialsWithoutCatalog(count: unreferenced.count)
            )
            return [:]

        case (.loaded, .enumerated):
            switch await vault.reconcile(records) {
            case .completed(let reauthenticated):
                catalog.setRecoveryAdvisory(nil)
                return reauthenticated

            // The three refusals are listed rather than matched with `_` so that a fourth one
            // cannot be added without someone deciding here what the user is told about it. All
            // three say the same true thing today: this launch could not finish checking the
            // credential store, so nothing about those credentials may be reported as settled.
            case .aborted(.enumerationRefused, let reauthenticated),
                 .aborted(.itemReadRefused, let reauthenticated),
                 .aborted(.itemDeleteRefused, let reauthenticated):
                catalog.setRecoveryAdvisory(.credentialStoreUnreachable)
                return reauthenticated
            }

        case (.loading, _):
            assertionFailure("AccountCatalog remained loading after load().")
            catalog.setRecoveryAdvisory(.credentialStoreUnreachable)
            return [:]
        }
    }
}
