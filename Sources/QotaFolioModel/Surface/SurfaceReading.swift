import Foundation

/// One window of one account, as a surface outside the app draws it: the provider's own name
/// for the limit, what is spent of it, and when it comes back. Nothing here predicts.
public nonisolated struct SurfaceWindow: Hashable, Sendable, Identifiable {
    /// `UsageReading.id` — the provider's scope and the window's length. The same key the
    /// history keeps the window's trace under and `recommendation.json` files its row text by.
    public let id: String
    /// The provider's display name for a scoped limit; `nil` for an account-wide one.
    public let scope: String?
    public let period: UsagePeriod
    /// Percent used, clamped to `0...100`.
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(reading: UsageReading) {
        id = reading.id
        scope = reading.scope
        period = reading.period
        usedPercent = min(100, max(0, reading.window.usedPercent))
        resetsAt = reading.window.resetsAt
    }

    /// Nothing left to spend in this window: the floored remaining percentage is zero.
    public var isSpent: Bool { remainingPercent(fromUsedPercent: usedPercent) == 0 }

    /// The whole number a surface prints. Floored, so a window at 37.2 % reads 37 and never
    /// overstates what is gone; a spent window reads 100 whatever the decimals said.
    public var wholePercentUsed: Int {
        isSpent ? 100 : Int(usedPercent.rounded(.down))
    }
}

/// One account, as a surface outside the app draws it.
public nonisolated struct SurfaceAccount: Hashable, Sendable, Identifiable {
    public let id: AccountID
    /// The person's own name for the account. A surface that is told names are hidden calls
    /// the account by its provider instead; the name is carried so the choice is the surface's.
    public let name: String
    public let provider: AccountProvider
    /// The order the person keeps their accounts in.
    public let order: Int
    /// The grant has lapsed, by the catalog's word. The last known numbers may still be here.
    public let needsSignIn: Bool
    public let level: AccountLevel
    /// Every window the provider reported whose number can be drawn, in the provider's order.
    public let windows: [SurfaceWindow]
    /// When the numbers were true. `nil` when there are none.
    public let observedAt: Date?
    public let planName: String?

    public init(
        id: AccountID,
        name: String,
        provider: AccountProvider,
        order: Int,
        needsSignIn: Bool,
        level: AccountLevel,
        windows: [SurfaceWindow],
        observedAt: Date?,
        planName: String?
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.order = order
        self.needsSignIn = needsSignIn
        self.level = level
        self.windows = windows
        self.observedAt = observedAt
        self.planName = planName
    }

    /// The account-wide short window, when the provider reports one.
    public var session: SurfaceWindow? { windows.first { $0.scope == nil && $0.period == .session } }
    /// The account-wide weekly window, when the provider reports one.
    public var weekly: SurfaceWindow? { windows.first { $0.scope == nil && $0.period == .weekly } }

    /// The soonest reset still ahead, across the account's windows.
    public func nextReset(after now: Date) -> Date? {
        windows.compactMap(\.resetsAt).filter { $0 > now }.min()
    }
}

/// What the app has written for the surfaces outside it, read whole.
///
/// The Control, the desktop widget and the `qota` command are separate processes. They cannot
/// see the store, so they see the files: the catalog for who the accounts are and in what order,
/// the snapshot book for what each one holds, and the group defaults for what the app is
/// keeping off screen right now. This is that read, once, into one value.
public nonisolated struct SurfaceReading: Hashable, Sendable {
    /// The accounts the person keeps visible, in their order.
    public let accounts: [SurfaceAccount]
    /// Whether the app is hiding account names — the screen is shared, or the person asked.
    public let namesHidden: Bool
    /// Which quantity the person has the batteries drawn to. The Control draws to the same one,
    /// so the two batteries a person can see at once are never two different measurements.
    public let stripShows: StripShows
    /// The instant the files were read.
    public let readAt: Date

    public init(
        accounts: [SurfaceAccount],
        namesHidden: Bool,
        stripShows: StripShows,
        readAt: Date
    ) {
        self.accounts = accounts
        self.namesHidden = namesHidden
        self.stripShows = stripShows
        self.readAt = readAt
    }

    /// The latest instant any account's numbers were true at.
    public var observedAt: Date? { accounts.compactMap(\.observedAt).max() }

    public func account(_ id: AccountID) -> SurfaceAccount? {
        accounts.first { $0.id == id }
    }

    /// What a read can come back with. Three answers, because a reader shows a different
    /// sentence for each: numbers, "open QotaFolio to add an account", or "cannot read".
    public enum Availability: Sendable {
        case reading(SurfaceReading)
        /// The app has never written a catalog here: it has not run, or it has no accounts yet.
        case noApp
        /// A file is there and this build cannot use it.
        case unreadable
    }

    /// This process's read of the app's files.
    ///
    /// `create: false` throughout — a reader has no business making directories.
    public static func read(
        identity: AppIdentity = .current,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> Availability {
        guard let container = try? SharedContainer.resolve(
            identity: identity,
            fileManager: fileManager,
            create: false
        ) else { return .noApp }
        return read(container: container, identity: identity, fileManager: fileManager, now: now)
    }

    public static func read(
        container: SharedContainer,
        identity: AppIdentity,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> Availability {
        let records: [AccountRecord]
        switch container.readBytes(.catalog, fileManager: fileManager) {
        case .absent:
            return .noApp
        case .unreadable:
            return .unreadable
        case .loaded(let data):
            guard case .loaded(let loaded) = AccountCatalogCodec.decode(data) else { return .unreadable }
            records = loaded
        }

        let snapshots: UsageSnapshotBook
        switch container.readBytes(.snapshots, fileManager: fileManager) {
        case .absent:
            snapshots = UsageSnapshotBook()
        case .unreadable:
            return .unreadable
        case .loaded(let data):
            let read: UsageHistoryRead<UsageSnapshotBook> = UsageHistoryCodec.decode(data)
            guard let book = read.book else { return .unreadable }
            snapshots = book
        }

        let defaults = SurfaceDefaults.read(identity: identity)
        let accounts = records
            .filter { !defaults.hiddenAccountIDs.contains($0.id) }
            .sorted { lhs, rhs in
                lhs.displayOrder == rhs.displayOrder
                    ? lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
                    : lhs.displayOrder < rhs.displayOrder
            }
            .map { record in
                let snapshot = snapshots.snapshot(for: record.id)?.makeUsageSnapshot()
                let needsSignIn = record.status == .needsReauthentication
                let reading = snapshot.flatMap { $0.provider == record.provider ? $0 : nil }
                return SurfaceAccount(
                    id: record.id,
                    name: record.name,
                    provider: record.provider,
                    order: record.displayOrder,
                    needsSignIn: needsSignIn,
                    level: AccountLevel.make(
                        provider: record.provider,
                        needsSignIn: needsSignIn,
                        hasSetupIssue: false,
                        isWaitingForFirstReading: true,
                        snapshot: snapshot
                    ),
                    windows: reading.map(windows(in:)) ?? [],
                    observedAt: reading?.fetchedAt,
                    planName: reading?.planName
                )
            }

        return .reading(SurfaceReading(
            accounts: accounts,
            namesHidden: defaults.namesHidden,
            stripShows: defaults.stripShows,
            readAt: now
        ))
    }

    /// Every window one snapshot reports whose number can be projected onto `0...100`, in the
    /// order the provider reports them. Nothing is invented for a window the provider did not
    /// send.
    public static func windows(in snapshot: UsageSnapshot) -> [SurfaceWindow] {
        snapshot.readings
            .filter { remainingPercent(fromUsedPercent: $0.window.usedPercent) != nil }
            .map(SurfaceWindow.init(reading:))
    }
}

/// The settings a surface outside the app has to know about, carried in the App Group's own
/// defaults suite.
///
/// The blanket, the hidden accounts and the battery's quantity live in the app's preferences
/// domain, which no other process can read. The app mirrors them here whenever they change, then
/// asks the Control and the widget to reload; the extension reads them on every render.
public nonisolated enum SurfaceDefaults {
    public static let namesHiddenKey = "surface.namesHidden.v1"
    public static let hiddenAccountIDsKey = "surface.hiddenAccountIDs.v1"
    public static let stripShowsKey = "surface.stripShows.v1"

    public struct Values: Hashable, Sendable {
        public let namesHidden: Bool
        public let hiddenAccountIDs: Set<AccountID>
        public let stripShows: StripShows

        public init(namesHidden: Bool, hiddenAccountIDs: Set<AccountID>, stripShows: StripShows) {
            self.namesHidden = namesHidden
            self.hiddenAccountIDs = hiddenAccountIDs
            self.stripShows = stripShows
        }

        public static let none = Values(namesHidden: false, hiddenAccountIDs: [], stripShows: .session)
    }

    /// The App Group's suite, which every process signed into the group reads and writes.
    public static func suite(for identity: AppIdentity) -> UserDefaults? {
        UserDefaults(suiteName: identity.appGroupIdentifier)
    }

    public static func read(identity: AppIdentity = .current) -> Values {
        guard let suite = suite(for: identity) else { return .none }
        let hidden = (suite.array(forKey: hiddenAccountIDsKey) as? [String] ?? [])
            .compactMap(UUID.init(uuidString:))
            .map(AccountID.init(rawValue:))
        return Values(
            namesHidden: suite.bool(forKey: namesHiddenKey),
            hiddenAccountIDs: Set(hidden),
            stripShows: suite.string(forKey: stripShowsKey)
                .flatMap(StripShows.init(rawValue:)) ?? .session
        )
    }

    /// Writes the values, and answers whether anything changed — so a caller reloads the
    /// surfaces only when there is something new for them to read.
    @discardableResult
    public static func write(_ values: Values, identity: AppIdentity = .current) -> Bool {
        guard let suite = suite(for: identity) else { return false }
        guard read(identity: identity) != values else { return false }
        suite.set(values.namesHidden, forKey: namesHiddenKey)
        suite.set(
            values.hiddenAccountIDs.map(\.rawValue.uuidString).sorted(),
            forKey: hiddenAccountIDsKey
        )
        suite.set(values.stripShows.rawValue, forKey: stripShowsKey)
        return true
    }
}

/// What one plain read of a shared file came back with.
public nonisolated enum SharedFileRead: Sendable {
    case absent
    case loaded(Data)
    /// Larger than this build will read, or not readable at all.
    case unreadable
}

extension SharedContainer {
    /// One file, read whole, from a process that only reads.
    ///
    /// The app's own writers walk descriptor-relative with `O_NOFOLLOW`; a reader of a file the
    /// app wrote atomically into its own group container needs none of that. The size is checked
    /// before the bytes are allocated, with the same bound the file's own reader applies.
    public func readBytes(_ file: SharedFile, fileManager: FileManager = .default) -> SharedFileRead {
        let url = self.url(for: file)
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size <= file.maximumBytes,
              let data = try? Data(contentsOf: url, options: [.uncached])
        else { return .unreadable }
        return .loaded(data)
    }
}
