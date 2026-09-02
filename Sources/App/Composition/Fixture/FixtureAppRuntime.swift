#if DEBUG
import AppKit
import SwiftUI
import QotaFolioCore
import QotaFolioKit
import QotaFolioKitFixtures
import UIFixtures

/// The app over fixture accounts: the real status item, the real panel, the real strip, and
/// nothing behind them but a scenario.
///
/// A debug build launched with `QOTAFOLIO_UI_SCENARIO=<name>` builds this instead of the
/// production runtime. It holds no grant, reaches no network and reads no Keychain, so a Mac
/// with no account can show the panel on `face`, `states`, `mixed`, `device-code`, `recovery`
/// or `empty`. The rest of the environment is the photographer's:
///
/// - `QOTAFOLIO_UI_APPEARANCE=dark` — the app's own windows wear `.darkAqua` (it is set as the
///   person's own choice, so the Settings picker shows it too) and a dark backdrop is put behind
///   them (the Sonoma wallpaper's dark representation, with the real strip drawn on it at the real
///   bar's geometry). `light` puts the light backdrop up. Unset, the real desktop shows.
/// - `QOTAFOLIO_UI_STRIP=session|week` — which quantity the menu-bar batteries are drawn to. Set
///   as the person's own choice, in this launch's throwaway defaults, so the Settings picker
///   shows it and the Control published beside it follows.
/// - `QOTAFOLIO_UI_BACKDROP=0` — the appearance without the backdrop, over the real desktop and
///   the real menu bar. This is how the one thing the choice must not do is checked: the panel
///   goes dark and the batteries stay with the bar they sit in.
/// - `QOTAFOLIO_UI_OPEN_PANEL=1` — the panel opens by itself once the item is placed, and the
///   process prints `QF_PANEL_FRAME` and `QF_CAPTURE_REGION` lines a script can hand to
///   `screencapture`.
/// - `QOTAFOLIO_UI_EXPANDED=<name>` / `QOTAFOLIO_UI_HOVER=<name>` — read by the card list.
/// - `QOTAFOLIO_UI_ACCOUNTS=<n>` — only the scenario's first `n` accounts are visible; the rest
///   are hidden the way a person hides them in Settings.
/// - `QOTAFOLIO_UI_TOGGLE=<name>@<ms>,<ms>,…` — that card is opened and closed at those times,
///   counted from the panel being up and settled, each printed as `QF_CARD_TOGGLE`. This is how
///   the panel's motion is watched: `QOTAFOLIO_UI_EXPANDED` can only open a card before the
///   panel is on screen, and this Mac takes no synthetic clicks.
/// - `QOTAFOLIO_UI_ACCOMMODATIONS=…` — read by the panel and the strip.
/// - `QOTAFOLIO_UI_KEYS=down,down,return` — once the panel is open, these keys are posted to
///   the application's event queue, so the keyboard walk is the real one: the key window gets
///   them, focus moves, Return opens, Escape closes. Only with keys does the panel take the
///   keyboard at all; otherwise it is ordered front without becoming key, so nobody's typing
///   is swallowed while a photograph is taken. Every key it does receive is printed as
///   `QF_KEY_EVENT`, and every mouse button event as `QF_MOUSE_EVENT`.
/// - `QOTAFOLIO_UI_KEY_WINDOW=1` — the panel takes the keyboard as it does for a person, with
///   no keys posted: for a pointer walk driven from outside, whose first click must reach the
///   view rather than merely wake the window.
/// - `QOTAFOLIO_UI_HIDE_NAMES=1` — the person's own blanket is on; `QOTAFOLIO_UI_SCREEN_SHARED=1`
///   — the probe reports a watched screen; `QOTAFOLIO_UI_NO_PROBE=1` — a Mac with no probe;
///   `QOTAFOLIO_UI_REAL_PROBE=1` — the real SkyLight probe, polled as the product polls it,
///   printing `QF_PROBE` once and `QF_SCREEN_WATCHED` on every change.
/// - `QOTAFOLIO_UI_PLACEMENT=hidden` — the panel is told macOS refused the item, and draws the
///   sentence that says so.
/// - `QOTAFOLIO_UI_ALERTS=1` — the fixture assessment's alerts go through the deliverer to a
///   recording centre that prints each as `QF_ALERT` instead of asking macOS.
/// - `QOTAFOLIO_UI_OPEN_SETTINGS=<general|accounts|alerts|privacy|updates|about>` — opens the
///   Settings window on that tab and prints `QF_SETTINGS_REGION`, with the window's number, for a
///   photograph.
///
/// The system is never switched: no appearance change, no accessibility setting, no wallpaper.
@MainActor
final class FixtureAppRuntime: AppRuntime {
    private let catalog: FixtureAccountCatalog
    private let store: FixtureAccountsStore
    private let addFlow: FixtureAddFlowPresenter
    private let visibility: FixtureAccountVisibilityController
    private let scheduler: AppCandidacyScheduler
    private let statusSurface: AppKitStatusItemSurface
    private let statusItem: StatusItemController
    private let panelController: MenuBarPanelController<PanelContentView>
    private let privacy: ScreenPrivacy
    private let alerts: AlertDeliverer
    private let alertCenter: FixtureAlertCenter
    private let surfaceRelay: SurfaceRelay
    private let stripPreferences: StripPreferences
    private let panelShortcut: GlobalShortcutStore
    private let settingsPresenter: SettingsWindowPresenter
    private let defaults: UserDefaults
    private let defaultsDomain: String
    private let scenario: FixtureUIScenario
    private let options: Options
    private var backdrop: FixtureBackdropWindow?
    private var previewWindows: [NSWindow] = []
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var resizeObserver: NSObjectProtocol?
    private var started = false

    struct Options {
        var appearance: NSAppearance.Name?
        /// Which quantity the batteries are drawn to.
        var stripShows: StripShows = .session
        var opensPanel = false
        var keys: [FixtureKey] = []
        var takesKeyboardFocus = false
        var namesHiddenByHand = false
        var screenShared = false
        var probeAvailable = true
        var realProbe = false
        var placementHidden = false
        var deliversAlerts = false
        var settingsTab: SettingsTab?
        /// The card the lab toggles, and when — milliseconds from the panel being up and settled.
        var cardToggle: (accountName: String, times: [Int])?
        /// Whether the wallpaper backdrop is put up behind the app.
        var showsBackdrop = true
        /// How many of the scenario's accounts are visible. The rest are hidden the way a person
        /// hides them in Settings.
        var visibleAccounts: Int?
    }

    /// A key the photographer can send: the same code and characters the keyboard would.
    enum FixtureKey: String {
        case down, up, `return`, space, escape, tab

        var keyCode: UInt16 {
            switch self {
            case .down: 125
            case .up: 126
            case .return: 36
            case .space: 49
            case .escape: 53
            case .tab: 48
            }
        }

        var characters: String {
            switch self {
            case .down: String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case .up: String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case .return: "\r"
            case .space: " "
            case .escape: "\u{1B}"
            case .tab: "\t"
            }
        }
    }

    static func make(environment: [String: String]) -> FixtureAppRuntime? {
        guard let name = environment["QOTAFOLIO_UI_SCENARIO"] else { return nil }
        guard let scenario = FixtureUIScenarios.named(name) else {
            fputs("QotaFolio: no fixture scenario named \(name)\n", stderr)
            return nil
        }
        var options = Options()
        switch environment["QOTAFOLIO_UI_APPEARANCE"] {
        case "dark": options.appearance = .darkAqua
        case "light": options.appearance = .aqua
        default: break
        }
        options.stripShows = environment["QOTAFOLIO_UI_STRIP"]
            .flatMap(StripShows.init(rawValue:)) ?? .session
        options.opensPanel = environment["QOTAFOLIO_UI_OPEN_PANEL"] == "1"
        options.keys = environment["QOTAFOLIO_UI_KEYS", default: ""]
            .split(separator: ",")
            .compactMap { FixtureKey(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        options.takesKeyboardFocus = !options.keys.isEmpty || environment["QOTAFOLIO_UI_KEY_WINDOW"] == "1"
        options.namesHiddenByHand = environment["QOTAFOLIO_UI_HIDE_NAMES"] == "1"
        options.screenShared = environment["QOTAFOLIO_UI_SCREEN_SHARED"] == "1"
        options.probeAvailable = environment["QOTAFOLIO_UI_NO_PROBE"] != "1"
        options.realProbe = environment["QOTAFOLIO_UI_REAL_PROBE"] == "1"
        options.placementHidden = environment["QOTAFOLIO_UI_PLACEMENT"] == "hidden"
        options.deliversAlerts = environment["QOTAFOLIO_UI_ALERTS"] == "1"
        options.settingsTab = environment["QOTAFOLIO_UI_OPEN_SETTINGS"].flatMap(SettingsTab.init(rawValue:))
        options.cardToggle = cardToggle(from: environment["QOTAFOLIO_UI_TOGGLE"])
        options.showsBackdrop = environment["QOTAFOLIO_UI_BACKDROP"] != "0"
        options.visibleAccounts = environment["QOTAFOLIO_UI_ACCOUNTS"].flatMap(Int.init)
        return FixtureAppRuntime(scenario: scenario, options: options)
    }

    /// `<account name>@<ms>,<ms>,…` — the card, and the times at which it is toggled, counted
    /// from the panel being up and settled. Without times it is toggled once, a second in.
    private static func cardToggle(from value: String?) -> (accountName: String, times: [Int])? {
        guard let value, !value.isEmpty else { return nil }
        let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let times = parts.count > 1
            ? parts[1].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            : []
        return (name, times.isEmpty ? [1000] : times.sorted())
    }

    private init(scenario: FixtureUIScenario, options: Options) {
        let catalog = FixtureAccountCatalog(
            accounts: scenario.accounts,
            loadState: scenario.loadState,
            recoveryAdvisory: scenario.recoveryAdvisory
        )
        let store = FixtureAccountsStore(snapshots: scenario.snapshots, pollStatus: scenario.pollStatus)
        if let history = scenario.history {
            store.traceBook = history.traces
            store.publish(history.assessment)
        }
        let addFlow = FixtureAddFlowPresenter(
            activeFlow: scenario.activeFlow,
            activeFlowProvider: scenario.activeFlowProvider,
            providersByAccount: Dictionary(uniqueKeysWithValues: scenario.accounts.map { ($0.id, $0.provider) })
        )
        // A fleet the size of the one being looked at. Five accounts fill the panel to its
        // ceiling and the list scrolls inside a window that never moves; two or three is the
        // shape most people have, and the shape in which the panel's own height is the motion.
        let hidden = options.visibleAccounts.map { Set(scenario.accounts.dropFirst(max(0, $0)).map(\.id)) } ?? []
        let visibility = FixtureAccountVisibilityController(hiddenAccountIDs: hidden)
        let scheduler = AppCandidacyScheduler()

        // Preferences of this launch's own, thrown away at quit: nothing a photograph sets
        // survives into the next one.
        let defaultsDomain = "net.c2coast.QotaFolio.fixture.\(ProcessInfo.processInfo.processIdentifier)"
        let defaults = UserDefaults(suiteName: defaultsDomain) ?? .standard
        defaults.removePersistentDomain(forName: defaultsDomain)
        let probe: any ScreenWatcherProbing = options.realProbe
            ? SkyLightScreenWatcherProbe()
            : FixtureScreenWatcherProbe(isAvailable: options.probeAvailable, watched: options.screenShared)
        let privacy = ScreenPrivacy(probe: probe, defaults: defaults)
        privacy.namesHiddenByHand = options.namesHiddenByHand
        let alertCenter = FixtureAlertCenter(status: .notDetermined, grantsWhenAsked: true)
        alertCenter.printsDeliveries = true
        let alertPreferences = AlertPreferences(defaults: defaults)
        let appearancePreferences = AppearancePreferences(defaults: defaults)
        let stripPreferences = StripPreferences(defaults: defaults)
        stripPreferences.shows = options.stripShows
        let alerts = AlertDeliverer(store: store, preferences: alertPreferences, center: alertCenter, defaults: defaults)

        // The same relay production runs, so a fixture launch reloads the Control and the
        // widget with the scenario it published. The fixture catalog holds no commit chain.
        let surfaceRelay = SurfaceRelay(
            catalog: catalog,
            store: store,
            visibility: visibility,
            privacy: privacy,
            stripShows: stripPreferences,
            drainCatalog: {}
        )

        let statusSurface = AppKitStatusItemSurface()
        let statusItem = StatusItemController(
            catalog: catalog,
            store: store,
            visibility: visibility,
            scheduler: scheduler,
            surface: statusSurface,
            privacy: privacy,
            stripShows: stripPreferences
        )
        let placementHidden = options.placementHidden
        let settingsRoute = FixtureSettingsRoute()
        let panelController = MenuBarPanelController(
            catalog: catalog,
            store: store,
            addFlow: addFlow,
            onPanelShown: { [weak statusItem] in statusItem?.panelDidBecomeVisible() },
            openSettings: { settingsRoute.presenter?.present() },
            content: { _, _, _ in
                PanelContentView(
                    catalog: catalog,
                    store: store,
                    addFlow: addFlow,
                    visibility: visibility,
                    privacy: privacy,
                    menuBarPlacement: { placementHidden ? .hiddenByMenuBarSettings : .placed }
                )
            }
        )
        // The fixture's own throwaway defaults, so a photograph's recording is discarded
        // at quit with everything else — and the same ⌃⌥Q as production, so the shortcut
        // can be proven on the real panel over fixture accounts.
        let panelShortcut = GlobalShortcutStore(defaults: defaults)

        let settingsPresenter = SettingsWindowPresenter(
            updater: FixtureSettingsUpdater(),
            launchAtLogin: FixtureLoginAtStartupController(),
            catalog: catalog,
            addFlow: addFlow,
            visibility: visibility,
            uninstall: FixtureUninstallPresenter(),
            alertPreferences: alertPreferences,
            alerts: alerts,
            privacy: privacy,
            panelShortcut: panelShortcut,
            appearance: appearancePreferences,
            stripShows: stripPreferences
        )
        settingsPresenter.initialTab = options.settingsTab ?? .general
        settingsPresenter.panel = panelController
        settingsRoute.presenter = settingsPresenter
        // The photographer's appearance is set as the person's own choice, in this launch's
        // throwaway defaults: one path, and the whole app then wears the form that was asked for
        // — the panel, the Settings window, and the picker showing which one it is.
        if let appearance = options.appearance {
            appearancePreferences.appearance = appearance == .darkAqua ? .dark : .light
        }
        panelController.appearanceSource = { [weak appearancePreferences] in
            appearancePreferences?.nsAppearance
        }
        // Only a keyboard walk needs the panel to have the keyboard. A photograph does not, and a
        // key panel would swallow whatever someone at this Mac types while it is up.
        panelController.takesKeyboardFocus = options.takesKeyboardFocus
        statusItem.panel = panelController

        self.scenario = scenario
        self.options = options
        self.catalog = catalog
        self.store = store
        self.addFlow = addFlow
        self.visibility = visibility
        self.scheduler = scheduler
        self.statusSurface = statusSurface
        self.statusItem = statusItem
        self.panelController = panelController
        self.privacy = privacy
        self.alerts = alerts
        self.alertCenter = alertCenter
        self.surfaceRelay = surfaceRelay
        self.stripPreferences = stripPreferences
        self.panelShortcut = panelShortcut
        self.settingsPresenter = settingsPresenter
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
    }

    var ordinaryTerminationIsAllowed: Bool { true }

    func start() {
        guard !started else { return }
        started = true
        // The same road the production runtime installs, so Spotlight photographed against a
        // fixture answers with the fixture's accounts and its Open lands on the real panel.
        QotaFolioIntentRuntime.install(revealPanel: { [weak self] in
            self?.statusItem.showPanel()
        })
        IntentServices.install(store: store, catalog: catalog, privacy: privacy, stripShows: stripPreferences)
        panelShortcut.activate { [weak self] in
            self?.statusItem.togglePanel()
        }
        // The Control, the widget and `qota` read files, and a fixture build holds none —
        // this writes the scenario into the group container through the real codecs, so those
        // surfaces can be photographed on a Mac with no grant.
        if ProcessInfo.processInfo.environment["QOTAFOLIO_UI_PUBLISH_FILES"] == "1" {
            publishScenarioFiles()
            surfaceRelay.start()
        }
        // The widget's own views, hosted in this process over the published reading, for a Mac
        // where nobody may drive the widget gallery. The same source files WidgetKit renders.
        if let spec = ProcessInfo.processInfo.environment["QOTAFOLIO_UI_WIDGET_PREVIEW"] {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                self?.showWidgetPreviews(spec)
            }
        }
        // The Control's battery symbols, loaded from the embedded extension's own compiled
        // catalog, at menu-bar size on both bar polarities.
        if ProcessInfo.processInfo.environment["QOTAFOLIO_UI_SYMBOL_PREVIEW"] == "1" {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                self?.showSymbolPreview()
            }
        }
        // Every key the panel receives while it is up, on record: a keyboard walk is expected
        // to appear here, a stranger's keystroke is not.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            print("QF_KEY_EVENT code=\(event.keyCode) chars=\(event.characters.map { $0.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ") } ?? "-")")
            fflush(stdout)
            return event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            let location = event.locationInWindow
            print("QF_MOUSE_EVENT type=\(event.type.rawValue) window=\(event.windowNumber) x=\(Int(location.x)) y=\(Int(location.y))")
            fflush(stdout)
            return event
        }
        // Every height the panel's window takes, on record with its top edge: a card opening is
        // expected to leave a run of heights along one curve with the top edge never moving; a
        // single jump from one height to the next is the two-clock fault.
        let startedAt = ProcessInfo.processInfo.systemUptime
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: nil) { [weak self] _ in
            // Window notifications are posted on the main thread, where the windows live.
            MainActor.assumeIsolated { self?.tracePanelResize(since: startedAt) }
        }
        store.start()
        if options.realProbe {
            print("QF_PROBE available=\(privacy.automaticFormIsAvailable) watched=\(privacy.screenIsWatched)")
            fflush(stdout)
            privacy.start()
            watchTheBlanket()
        }
        if options.deliversAlerts {
            alerts.start()
            // The fixture week rarely has an alert due at photograph time, so one is put into
            // the published assessment by hand: a fresh five-hour window on the first account.
            // Everything after that — the sentence, the once-per-key rule, the permission ask
            // — is the app's own, ending at the recording centre instead of macOS.
            if let base = store.assessment, let first = base.accounts.first {
                let fresh = FleetAlert(
                    kind: .freshWindow(windowKey: "session", since: scheduler.now),
                    account: first.id,
                    key: "fixture|fresh-window|\(first.id.rawValue.uuidString)"
                )
                store.publish(FleetAssessment(
                    generatedAt: base.generatedAt,
                    accounts: base.accounts,
                    alerts: base.alerts + [fresh],
                    nextReviewAt: base.nextReviewAt,
                    activity: base.activity
                ))
            }
        }
        if let tab = options.settingsTab {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self else { return }
                self.settingsPresenter.initialTab = tab
                self.settingsPresenter.present()
                try? await Task.sleep(for: .milliseconds(900))
                self.printSettingsRegion()
            }
            return
        }
        guard options.appearance != nil || options.opensPanel else { return }
        // The item's window arrives after launch; give macOS the settling time the surface
        // itself waits for before reading where the batteries landed.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self else { return }
            if let appearance = self.options.appearance, self.options.showsBackdrop {
                self.showBackdrop(dark: appearance == .darkAqua)
            }
            guard self.options.opensPanel else { return }
            try? await Task.sleep(for: .milliseconds(200))
            self.statusItem.showPanel()
            try? await Task.sleep(for: .milliseconds(900))
            await self.sendKeys()
            self.printCaptureRegion()
            await self.runCardToggles()
        }
    }

    /// Opens and closes a card on the clock the lab asked for, so the panel's one motion can be
    /// watched — and recorded — without a pointer or a keystroke on this Mac.
    private func runCardToggles() async {
        guard let toggle = options.cardToggle else { return }
        var elapsed = 0
        for time in toggle.times {
            try? await Task.sleep(for: .milliseconds(max(0, time - elapsed)))
            elapsed = max(elapsed, time)
            DebugCardToggle.post(accountNamed: toggle.accountName)
            print("QF_CARD_TOGGLE t=\(elapsed) name=\(toggle.accountName)")
            fflush(stdout)
        }
    }

    func revealPrimarySurface() {
        guard started else { return }
        statusItem.showPanel()
    }

    func beginOrdinaryTermination() async {
        guard started else { return }
        started = false
        panelController.hide(reason: .termination)
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        backdrop?.orderOut(nil)
        backdrop = nil
        for window in previewWindows { window.orderOut(nil) }
        previewWindows.removeAll()
        store.stop()
        statusItem.remove()
        privacy.stop()
        surfaceRelay.stop()
        panelShortcut.deactivate()
        defaults.removePersistentDomain(forName: defaultsDomain)
    }

    /// Writes the scenario's catalog, snapshots and recommendation into this build's group
    /// container, exactly as the app writes them: the same codecs, atomic writes, the same
    /// leaf names. `QF_PUBLISHED` prints the directory so a script can hand it to `qota`.
    private func publishScenarioFiles() {
        do {
            let container = try SharedContainer.resolve()
            try FileManager.default.createDirectory(
                at: container.directoryURL,
                withIntermediateDirectories: true
            )
            let records = scenario.accounts.map(AccountRecord.init(config:))
            try AccountCatalogCodec.encode(records)
                .write(to: container.url(for: .catalog), options: [.atomic])

            var book = UsageSnapshotBook()
            for (id, snapshot) in scenario.snapshots {
                book.record(PersistedUsageSnapshot(account: id, snapshot: snapshot))
            }
            if let data = UsageHistoryCodec.encode(book, for: .snapshots) {
                try data.write(to: container.url(for: .snapshots), options: [.atomic])
            }

            let assessment = scenario.history?.assessment ?? FleetAssessment.silent(
                at: scenario.now,
                accounts: scenario.accounts.map(FleetAccount.init(config:))
            )
            let document = RecommendationDocument(
                assessment: assessment,
                sentences: AssessmentSentences.recommendation(assessment)
            )
            if let data = RecommendationCodec.encode(document) {
                try data.write(to: container.url(for: .recommendation), options: [.atomic])
            }
            print("QF_PUBLISHED \(container.directoryURL.path)")
        } catch {
            print("QF_PUBLISH_FAILED \(error)")
        }
        fflush(stdout)
    }

    // MARK: - Widget and symbol previews: the extension's faces in this process's own windows

    /// Hosts the widget's real views — the ones `Sources/Surfaces` compiles into the extension
    /// — at the widget's sizes, over the published reading, and prints one capture region.
    private func showWidgetPreviews(_ spec: String) {
        guard case .reading(let reading) = SurfaceReading.read() else {
            print("QF_WIDGET_PREVIEW no-reading")
            fflush(stdout)
            return
        }
        var x: CGFloat = 240
        let y: CGFloat = 420
        var frames: [NSRect] = []
        for kind in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let dark = kind.hasSuffix("dark")
            let size = kind.hasPrefix("medium") ? NSSize(width: 360, height: 170) : NSSize(width: 170, height: 170)
            let content: AnyView = kind.hasPrefix("medium")
                ? AnyView(MediumFleetView(reading: reading, now: Date()))
                : AnyView(SmallFleetView(reading: reading, now: Date()))
            let root = content
                .padding(14)
                .frame(width: size.width, height: size.height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            let window = NSPanel(
                contentRect: NSRect(origin: NSPoint(x: x, y: y), size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.isReleasedWhenClosed = false
            if dark { window.appearance = NSAppearance(named: .darkAqua) }
            window.contentView = NSHostingView(rootView: root)
            window.orderFrontRegardless()
            previewWindows.append(window)
            frames.append(window.frame)
            x += size.width + 36
        }
        printCaptureRegion(around: frames, label: "QF_WIDGET_REGION")
    }

    /// The 23 generated battery symbols, straight out of the embedded extension's compiled
    /// asset catalog, at menu-bar point size on a light and a dark bar.
    private func showSymbolPreview() {
        let appexURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/QotaFolioWidgets.appex")
        guard let appex = Bundle(url: appexURL) else {
            print("QF_SYMBOL_PREVIEW no-appex")
            fflush(stdout)
            return
        }
        let names = stride(from: 0, through: 100, by: 20).map { "qf.battery.\($0)" }
            + ["qf.battery.spent", "qf.battery.empty"]
        let images = names.compactMap { name in
            appex.image(forResource: name).map { (name, $0) }
        }
        print("QF_SYMBOL_PREVIEW loaded=\(images.count) of \(names.count)")

        func row(_ dark: Bool) -> some View {
            HStack(spacing: 14) {
                ForEach(images, id: \.0) { _, image in
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 14)
                        .foregroundStyle(dark ? Color.white : Color.black.opacity(0.9))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(dark ? Color(white: 0.12) : Color(white: 0.94))
        }
        let root = VStack(spacing: 0) { row(false); row(true) }
        let size = NSSize(width: CGFloat(images.count) * 34 + 48, height: 68)
        let window = NSPanel(
            contentRect: NSRect(x: 240, y: 640, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.hasShadow = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderFrontRegardless()
        previewWindows.append(window)
        printCaptureRegion(around: [window.frame], label: "QF_SYMBOL_REGION")
    }

    /// One `screencapture -R` region, top-left coordinates, covering the given frames with air.
    private func printCaptureRegion(around frames: [NSRect], label: String) {
        guard let primary = NSScreen.screens.first, !frames.isEmpty else { return }
        let union = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        let margin: CGFloat = 28
        let x = Int(union.minX - margin - primary.frame.minX)
        let y = Int(primary.frame.maxY - union.maxY - margin)
        print("\(label) \(x),\(y),\(Int(union.width + margin * 2)),\(Int(union.height + margin * 2))")
        fflush(stdout)
    }

    // MARK: - The backdrop: the wallpaper with the batteries on it

    /// Puts the Sonoma wallpaper's light or dark representation behind the panel, above the
    /// real menu bar, with the strip drawn where the real item is. The panel's Liquid Glass
    /// samples this window through the window server, so a dark form is a real dark backdrop
    /// and a `.darkAqua` panel — the Mac's appearance is never switched.
    private func showBackdrop(dark: Bool) {
        guard let screen = statusSurface.statusButtonScreenFrame.flatMap(screenContaining) ?? NSScreen.main else { return }
        let strip = StatusStripModel.make(
            catalog: projectedVisibleAccounts(catalog.accounts, using: visibility),
            loadState: catalog.loadState,
            snapshots: store.snapshots,
            pollStatus: store.pollStatus,
            now: scheduler.now
        )
        let accommodations = DebugAccommodations()
        let stripImage = StatusStripRenderer().image(
            for: strip.cells,
            appearance: dark ? .darkAqua : .aqua,
            increaseContrast: accommodations.increaseContrast,
            differentiateWithoutColor: accommodations.differentiateWithoutColor,
            showing: options.stripShows
        )
        let image = FixtureBackdrop.image(
            dark: dark,
            screen: screen,
            strip: stripImage,
            at: statusSurface.statusButtonScreenFrame
        )
        let window = FixtureBackdropWindow(screen: screen, image: image)
        window.orderFrontRegardless()
        backdrop = window
    }

    private func screenContaining(_ rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    /// Prints every change of the automatic blanket, so a shell that starts a screen recording
    /// can read the flag flip on and off in this process's log.
    private func watchTheBlanket() {
        withObservationTracking {
            _ = privacy.screenIsWatched
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                print("QF_SCREEN_WATCHED \(self.privacy.screenIsWatched)")
                fflush(stdout)
                self.watchTheBlanket()
            }
        }
    }

    /// Where the Settings window is, for a script to photograph it — the same coordinates as
    /// `printCaptureRegion`, 24 pt of air on every side.
    private func printSettingsRegion() {
        guard let window = NSApp.windows.first(where: { $0.title.contains("Settings") && $0.isVisible }),
              let primary = NSScreen.screens.first
        else {
            print("QF_SETTINGS_FRAME none")
            fflush(stdout)
            return
        }
        let frame = window.frame
        let screen = screenContaining(frame) ?? primary
        let margin: CGFloat = 24
        let x = max(screen.frame.minX, frame.minX - margin)
        let right = min(screen.frame.maxX, frame.maxX + margin)
        let top = max(screen.frame.minY, screen.frame.maxY - frame.maxY - margin)
        let bottom = min(screen.frame.maxY, screen.frame.maxY - frame.minY + margin)
        let originX = Int(x - primary.frame.minX)
        let originY = Int(primary.frame.maxY - screen.frame.maxY + top)
        // The window number as well, for the same reason the panel prints one: a Settings window
        // is an ordinary window, so it sits under whatever application is active, and only
        // `screencapture -l<number>` can photograph it without taking the keyboard off somebody.
        print("QF_SETTINGS_REGION \(originX),\(originY),\(Int(right - x)),\(Int(bottom - top)) win=\(window.windowNumber)")
        fflush(stdout)
    }

    private var visiblePanel: MenuBarPanel? {
        NSApp.windows.first { $0 is MenuBarPanel && $0.isVisible } as? MenuBarPanel
    }

    private var lastTracedPanelFrame: NSRect?

    /// One `QF_PANEL_RESIZE` line per new panel frame: the time since the runtime started, the
    /// height, and where the top edge is.
    private func tracePanelResize(since startedAt: TimeInterval) {
        guard let panel = visiblePanel else { return }
        let frame = panel.frame
        guard frame != lastTracedPanelFrame else { return }
        lastTracedPanelFrame = frame
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        print("QF_PANEL_RESIZE t=\(elapsed) h=\(Int(frame.height.rounded())) top=\(Int(frame.maxY.rounded()))")
        fflush(stdout)
    }

    // MARK: - The keyboard walk

    /// Posts each requested key as a key-down/key-up pair, a quarter of a second apart, to the
    /// application's event queue — the path a real keystroke takes, so the app's current event
    /// is a key event and focus shows itself the way it does for a typist.
    private func sendKeys() async {
        guard !options.keys.isEmpty, let panel = visiblePanel else { return }
        for key in options.keys {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(
                    with: type,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber,
                    context: nil,
                    characters: key.characters,
                    charactersIgnoringModifiers: key.characters,
                    isARepeat: false,
                    keyCode: key.keyCode
                ) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        print("QF_KEYS \(options.keys.map(\.rawValue).joined(separator: ",")) key=\(panel.isKeyWindow)")
        fflush(stdout)
    }

    /// Where the panel is, for a script to photograph it. `screencapture -R` takes top-left
    /// points on the primary display's coordinate space; the region runs from the top of the
    /// screen (so the batteries are in the picture) to 24 pt below the panel, 40 pt either side.
    private func printCaptureRegion() {
        guard let panel = NSApp.windows.first(where: { $0 is MenuBarPanel && $0.isVisible }),
              let primary = NSScreen.screens.first
        else {
            print("QF_PANEL_FRAME none")
            fflush(stdout)
            return
        }
        let frame = panel.frame
        // The slab is where the region is measured from, and neither rectangle is the picture.
        // The window is the room the panel was given: it stands still at the full height the panel
        // is allowed while the glass moves inside it, and it carries the shadow's room on every
        // side, so framing on the window carries bare desktop either side and cuts the room under
        // the panel. The slab on its own is the other mistake — the glass's shadow falls *outside*
        // the slab, about thirty points of it at the sides and forty below, so a region hugging
        // the slab would cut the shadow off. What a picture of this panel wants is the slab, the
        // air its shadow falls into, and a little clean desktop past that.
        let drawn = panelController.glassFrame ?? frame
        let screen = screenContaining(frame) ?? primary
        let air: CGFloat = 8
        let margin = PanelLayout.shadowRoom.side + air
        let x = max(screen.frame.minX, drawn.minX - margin)
        let right = min(screen.frame.maxX, drawn.maxX + margin)
        let bottom = min(
            screen.frame.maxY,
            (screen.frame.maxY - drawn.minY) + PanelLayout.shadowRoom.bottom + air
        )
        // Top-left coordinates, relative to the primary display's top-left corner.
        let originX = Int(x - primary.frame.minX)
        let originY = Int(primary.frame.maxY - screen.frame.maxY)
        // The window number as well, so a recording can be taken of this panel alone
        // (`screencapture -l<number>`) on a Mac where another build of the app is also on screen.
        print("QF_PANEL_FRAME \(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)) win=\(panel.windowNumber)")
        print("QF_CAPTURE_REGION \(originX),\(originY),\(Int(right - x)),\(Int(bottom))")
        fflush(stdout)
    }
}

/// The wallpaper with the batteries drawn on it, at the screen's size and scale.
enum FixtureBackdrop {
    static let sonoma = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Sonoma.heic")

    static func image(dark: Bool, screen: NSScreen, strip: NSImage, at buttonFrame: NSRect?) -> CGImage? {
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        guard let context = CGContext(
            data: nil,
            width: Int((size.width * scale).rounded()),
            height: Int((size.height * scale).rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high

        if let source = CGImageSourceCreateWithURL(sonoma as CFURL, nil),
           CGImageSourceGetCount(source) >= 2,
           let wallpaper = CGImageSourceCreateImageAtIndex(source, dark ? 1 : 0, nil) {
            // Aspect fill, centred — the way the desktop shows it.
            let imageAspect = CGFloat(wallpaper.width) / CGFloat(wallpaper.height)
            let targetAspect = size.width / size.height
            var drawSize = size
            if imageAspect > targetAspect {
                drawSize.width = size.height * imageAspect
            } else {
                drawSize.height = size.width / imageAspect
            }
            let origin = CGPoint(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2)
            context.draw(wallpaper, in: CGRect(origin: origin, size: drawSize))
        } else {
            context.setFillColor(dark ? CGColor(gray: 0.12, alpha: 1) : CGColor(gray: 0.92, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
        }

        if let buttonFrame, let stripImage = strip.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let stripRect = NSRect(
                x: buttonFrame.midX - strip.size.width / 2 - screen.frame.minX,
                y: buttonFrame.midY - strip.size.height / 2 - screen.frame.minY,
                width: strip.size.width,
                height: strip.size.height
            )
            context.draw(stripImage, in: stripRect)
        }
        return context.makeImage()
    }
}

/// The screen-filling window that carries the backdrop. Above every ordinary window and above
/// the real menu bar, so the band is the only thing in the bar; below the panel, which sits at
/// `.popUpMenu`. It ignores the mouse.
final class FixtureBackdropWindow: NSWindow {
    init(screen: NSScreen, image: CGImage?) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contents = image
        view.layer?.contentsGravity = .resize
        contentView = view
    }
}

/// Hands the panel's Open Settings to a presenter built after the panel: the panel needs the
/// route before the presenter exists, and the presenter needs the panel.
@MainActor
private final class FixtureSettingsRoute {
    var presenter: SettingsWindowPresenter?
}
#endif
