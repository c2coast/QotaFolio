import Foundation
import Observation
import WidgetKit
import QotaFolioCore

/// Keeps the surfaces outside the app — the Control and the desktop widget — showing what the
/// app shows, and never asks them to redraw for nothing.
///
/// Two jobs, in one order. First it mirrors into the group's own defaults the settings the
/// extension cannot see: the privacy blanket, the hidden accounts, and which quantity the
/// batteries are drawn to. Then it asks WidgetKit to reload — and only when the **rendered**
/// facts changed: a poll that returns the same whole percentages reloads nothing, because the
/// reload budget is the surfaces' battery. The files themselves are already fresh when this
/// fires: the history writer publishes the snapshot book and the recommendation before the store
/// ever sees the assessment this relay observes.
@MainActor public final class SurfaceRelay {
    /// The kind strings, as the extension declares them. Spelled here too because the two
    /// targets share no source file; `SurfaceRelayTests` pins the pair against drift.
    public static let fleetWidgetKind = "QotaFolio.Fleet"
    public static let accountControlKind = "QotaFolio.Account"

    /// What a surface would render, quantised exactly as a surface renders it.
    private struct RowDigest: Hashable {
        let key: String
        let wholePercentUsed: Int
        let resetsAt: Date?
    }

    private struct AccountDigest: Hashable {
        let id: AccountID
        let name: String
        let provider: AccountProvider
        let level: AccountLevel
        let rows: [RowDigest]
    }

    private struct Digest: Hashable {
        let accounts: [AccountDigest]
        let namesHidden: Bool
        let hiddenAccountIDs: Set<AccountID>
        let stripShows: StripShows
    }

    private let catalog: any AccountCataloging
    private let store: any AccountsStoring
    private let visibility: any AccountVisibilityControlling
    private let privacy: ScreenPrivacy?
    /// Which quantity the batteries are drawn to. The Control draws one battery for one account
    /// and follows this the way the strip does.
    private let stripShows: StripPreferences?
    /// Waits for the catalog's file commit chain, so a rename's reload reads the renamed file.
    private let drainCatalog: @MainActor () async -> Void
    /// Where those settings go. Production writes the group defaults; a test records.
    private let mirror: @MainActor (SurfaceDefaults.Values) -> Void
    /// The reload itself. Production asks WidgetKit; a test counts.
    private let reloadSurfaces: @MainActor () -> Void

    private var last: Digest?
    private var isStopped = false
    private var rebuildScheduled = false
    private var chain: Task<Void, Never> = Task {}

    public init(
        catalog: any AccountCataloging,
        store: any AccountsStoring,
        visibility: any AccountVisibilityControlling,
        privacy: ScreenPrivacy?,
        stripShows: StripPreferences? = nil,
        drainCatalog: @escaping @MainActor () async -> Void,
        mirror: @escaping @MainActor (SurfaceDefaults.Values) -> Void = { values in
            SurfaceDefaults.write(values)
        },
        reloadSurfaces: @escaping @MainActor () -> Void = {
            ControlCenter.shared.reloadControls(ofKind: SurfaceRelay.accountControlKind)
            WidgetCenter.shared.reloadTimelines(ofKind: SurfaceRelay.fleetWidgetKind)
        }
    ) {
        self.catalog = catalog
        self.store = store
        self.visibility = visibility
        self.privacy = privacy
        self.stripShows = stripShows
        self.drainCatalog = drainCatalog
        self.mirror = mirror
        self.reloadSurfaces = reloadSurfaces
    }

    public func start() {
        guard !isStopped else { return }
        armObservation()
        scheduleSync()
    }

    public func stop() {
        isStopped = true
    }

    /// Returns once every sync scheduled so far has run. For tests, which otherwise race a
    /// chain they cannot see.
    public func settle() async {
        await chain.value
    }

    private func armObservation() {
        guard !isStopped else { return }
        withObservationTracking {
            // The assessment is the pulse: the store publishes it after every poll and every
            // reassessment, and — decisive for the reload — after the files have been written.
            // The snapshots are read too, because what the digest quantises is the snapshot,
            // and a store that moved one without an assessment must still be seen.
            _ = store.assessment
            _ = store.snapshots
            let accounts = catalog.accounts
            _ = accounts.map { visibility.isVisible($0.id) }
            _ = catalog.loadState
            _ = store.pollStatus
            _ = privacy?.isBlanketed
            _ = stripShows?.shows
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isStopped, !self.rebuildScheduled else { return }
                self.rebuildScheduled = true
                await Task.yield()
                guard !self.isStopped else { return }
                self.rebuildScheduled = false
                self.scheduleSync()
                self.armObservation()
            }
        }
    }

    private func scheduleSync() {
        let previous = chain
        chain = Task { @MainActor [weak self] in
            await previous.value
            guard let self, !self.isStopped else { return }
            // A rename or reorder reaches the file through the catalog's commit chain; the
            // reload must not outrun it.
            await self.drainCatalog()
            guard !self.isStopped else { return }
            let digest = self.makeDigest()
            guard digest != self.last else { return }
            self.last = digest
            self.mirror(SurfaceDefaults.Values(
                namesHidden: digest.namesHidden,
                hiddenAccountIDs: digest.hiddenAccountIDs,
                stripShows: digest.stripShows
            ))
            self.reloadSurfaces()
        }
    }

    private func makeDigest() -> Digest {
        let accounts = catalog.accounts
        let hidden = Set(accounts.filter { !visibility.isVisible($0.id) }.map(\.id))
        let visible = accounts.filter { !hidden.contains($0.id) }
        return Digest(
            accounts: visible.map { account in
                let snapshot = store.snapshots[account.id]
                let reading = snapshot.flatMap { $0.provider == account.provider ? $0 : nil }
                return AccountDigest(
                    id: account.id,
                    name: account.name,
                    provider: account.provider,
                    level: AccountLevel.make(
                        account: account,
                        snapshot: snapshot,
                        status: store.pollStatus[account.id]
                    ),
                    rows: (reading.map(SurfaceReading.windows(in:)) ?? []).map { window in
                        RowDigest(
                            key: window.id,
                            wholePercentUsed: window.wholePercentUsed,
                            resetsAt: window.resetsAt
                        )
                    }
                )
            },
            namesHidden: privacy?.isBlanketed ?? false,
            hiddenAccountIDs: hidden,
            stripShows: stripShows?.shows ?? .session
        )
    }
}
