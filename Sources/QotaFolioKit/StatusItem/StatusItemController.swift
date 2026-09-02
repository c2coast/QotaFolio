import Foundation
import Observation
import OSLog
import QotaFolioCore

@MainActor @Observable public final class StatusItemController {
    @ObservationIgnored private let catalog: any AccountCataloging
    @ObservationIgnored private let store: any AccountsStoring
    @ObservationIgnored private let visibility: any AccountVisibilityControlling
    @ObservationIgnored private let scheduler: any CandidacyScheduling
    @ObservationIgnored private let surface: any StatusItemSurface
    /// The privacy blanket, when the app has one: names off the strip's words, colour off
    /// the batteries, while the screen is watched or the person asked.
    @ObservationIgnored private let privacy: ScreenPrivacy?
    /// Which quantity the batteries are drawn to. Nil is the default one, this session.
    @ObservationIgnored private let stripShows: StripPreferences?

    @ObservationIgnored public weak var panel: (any PanelToggling)? {
        didSet { surface.panel = panel }
    }

    /// Whether macOS actually put the batteries on the menu bar.
    ///
    /// Observed, because the panel draws the sentence that sends the user to System Settings →
    /// Menu Bar. It is also logged once per change, since nothing outside this process can see
    /// where macOS actually put the item.
    public private(set) var menuBarPlacement: MenuBarPlacement = .pending

    @ObservationIgnored private var lastStrip: StatusStripModel?
    @ObservationIgnored private var lastAppearance: MenuBarAppearance?
    @ObservationIgnored private var lastColourless = false
    @ObservationIgnored private var lastShows: StripShows = .session
    @ObservationIgnored private var resetWake: (any CandidacyWake)?
    @ObservationIgnored private var resetWakeDeadline: Date?
    @ObservationIgnored private var observationRebuildScheduled = false
    @ObservationIgnored private var isRemoved = false
    @ObservationIgnored private let log = Logger(
        subsystem: AppIdentity.current.bundleID,
        category: "menu-bar"
    )

    public init(
        catalog: any AccountCataloging,
        store: any AccountsStoring,
        visibility: any AccountVisibilityControlling,
        scheduler: any CandidacyScheduling,
        surface: any StatusItemSurface = AppKitStatusItemSurface(),
        privacy: ScreenPrivacy? = nil,
        stripShows: StripPreferences? = nil
    ) {
        self.catalog = catalog
        self.store = store
        self.visibility = visibility
        self.scheduler = scheduler
        self.surface = surface
        self.privacy = privacy
        self.stripShows = stripShows

        // The item's window arrives after this initializer returns, so the answer to
        // "did macOS put it on the bar" cannot be read here. The surface says when it can.
        surface.onPlacementChange = { [weak self] in self?.readPlacement() }

        rebuildStrip()
        armObservation()
    }

    public func panelDidBecomeVisible() {
        rebuildStrip()
    }

    /// Shows the panel without a click on the status item.
    ///
    /// The reveal paths use this: a second launch of the app, and the reopen Finder sends when
    /// the user opens an app that is already running. It answers nothing once the status item
    /// has been removed — a quit or an uninstall has taken the anchor away, and a panel with no
    /// status item to hang from is not a surface any user asked for.
    public func showPanel() {
        guard !isRemoved else { return }
        surface.showPanel()
    }

    /// The global shortcut's click: the same toggle the mouse performs on the batteries.
    public func togglePanel() {
        guard !isRemoved else { return }
        surface.togglePanel()
    }

    public func remove() {
        guard !isRemoved else { return }
        isRemoved = true
        cancelWake()
        surface.panel = nil
        surface.onPlacementChange = nil
        panel = nil
        surface.remove()
    }

    public func clearSavedStateAndRemove() {
        guard !isRemoved else { return }
        isRemoved = true
        cancelWake()
        surface.panel = nil
        surface.onPlacementChange = nil
        panel = nil
        surface.clearSavedStateAndRemove()
    }

    private func armObservation() {
        guard !isRemoved else { return }

        withObservationTracking {
            let accounts = catalog.accounts
            _ = accounts.map { visibility.isVisible($0.id) }
            _ = catalog.loadState
            _ = store.snapshots
            _ = store.pollStatus
            _ = privacy?.isBlanketed
            _ = stripShows?.shows
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isRemoved, !self.observationRebuildScheduled else { return }
                self.observationRebuildScheduled = true
                await Task.yield()
                guard !self.isRemoved else { return }
                self.observationRebuildScheduled = false
                self.rebuildStrip()
                self.armObservation()
            }
        }
    }

    private func rebuildStrip() {
        guard !isRemoved else { return }

        let now = scheduler.now
        let allAccounts = catalog.accounts
        let visibleAccounts = projectedVisibleAccounts(allAccounts, using: visibility)
        let blanketed = privacy?.isBlanketed ?? false
        let strip: StatusStripModel
        if isDefensiveZeroVisibleState(
            allAccounts: allAccounts,
            visibleAccounts: visibleAccounts,
            loadState: catalog.loadState
        ) {
            strip = noVisibleAccountsStrip()
        } else {
            strip = StatusStripModel.make(
                catalog: visibleAccounts,
                loadState: catalog.loadState,
                snapshots: store.snapshots,
                pollStatus: store.pollStatus,
                now: now,
                namesHidden: blanketed
            )
        }
        let appearance = surface.currentAppearance
        let shows = stripShows?.shows ?? .session

        if strip != lastStrip
            || appearance != lastAppearance
            || blanketed != lastColourless
            || shows != lastShows {
            surface.apply(strip, appearance: appearance, colourless: blanketed, showing: shows)
            lastStrip = strip
            lastAppearance = appearance
            lastColourless = blanketed
            lastShows = shows
        }

        reconcileWake(nextReset(in: strip, from: now))
    }

    /// Whether macOS hosted the item.
    ///
    /// Asked only when the surface says the answer has settled, and never on the app's own
    /// schedule. A frame read while macOS is still placing the item is a coin toss — an
    /// accepted item passes through the refused proxy's exact shape on its way to the bar —
    /// so a rebuild triggered by a poll mid-flight would report a refusal that is not one.
    ///
    /// Logged once per change and never again: a refusal is a standing condition, and a line
    /// per poll about a standing condition is noise the user pays for in disk.
    private func readPlacement() {
        let placement = surface.placement
        guard placement != menuBarPlacement else { return }
        menuBarPlacement = placement
        switch placement {
        case .pending:
            break
        case .placed:
            // The frame this was read from, once per launch. A status item is hosted by
            // Control Center rather than by this app, so no window list outside the process
            // can see it: this line is the only record of where macOS actually put it.
            log.info("Menu-bar item placed. Window \(self.surface.placementDescription, privacy: .public).")
        case .hiddenByMenuBarSettings:
            log.error(
                """
                The menu-bar item was refused by macOS — System Settings > Menu Bar > \
                Allow in the Menu Bar. Window \(self.surface.placementDescription, privacy: .public).
                """
            )
        }
    }

    private func isDefensiveZeroVisibleState(
        allAccounts: [AccountConfig],
        visibleAccounts: [AccountConfig],
        loadState: CatalogLoadState
    ) -> Bool {
        guard !allAccounts.isEmpty, visibleAccounts.isEmpty else { return false }
        switch loadState {
        case .missing, .loaded:
            return true
        case .loading, .unreadable:
            return false
        }
    }

    private func noVisibleAccountsStrip() -> StatusStripModel {
        let message = qfLocalized(
            "strip.noVisibleAccounts",
            defaultValue: "No accounts are visible. Open Settings to show one.",
            comment: "Menu-bar strip words when configured accounts exist but every account is hidden."
        )
        return .saying(message)
    }

    /// When the strip's own words stop being true without another poll.
    ///
    /// A spent account counts down to its return in the tooltip and in what VoiceOver reads,
    /// so the strip is re-made at the soonest of those instants even if nothing else happens.
    private func nextReset(in strip: StatusStripModel, from now: Date) -> Date? {
        strip.cells
            .compactMap(\.minutesToReturn)
            .min()
            .map { now.addingTimeInterval(TimeInterval($0) * 60) }
    }

    private func reconcileWake(_ deadline: Date?) {
        guard deadline != resetWakeDeadline else { return }
        cancelWake()

        guard let deadline else { return }
        resetWakeDeadline = deadline
        // Thirty seconds of leeway, so macOS can fold this wake into work it was already
        // doing. This app runs all day: a tolerance-free timer buys its own wake-up every
        // time it fires, and half a minute of drift on a status-item refresh is invisible.
        resetWake = scheduler.schedule(at: deadline, tolerance: 30) { [weak self] in
            guard let self, !self.isRemoved else { return }
            self.resetWake = nil
            self.resetWakeDeadline = nil
            self.rebuildStrip()
        }
    }

    private func cancelWake() {
        resetWake?.cancel()
        resetWake = nil
        resetWakeDeadline = nil
    }
}
