import Foundation

/// One window of one account, as `qota status` prints it: the provider's own name for the
/// limit, what is spent of it, and when it comes back. Nothing here predicts.
public nonisolated struct SurfaceWindow: Hashable, Sendable, Identifiable {
    /// `UsageReading.id` — the provider's scope and the window's length. The same key the
    /// history keeps the window's trace under.
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

    /// The whole number `qota` prints. Floored, so a window at 37.2 % reads 37 and never
    /// overstates what is gone; a spent window reads 100 whatever the decimals said.
    public var wholePercentUsed: Int {
        isSpent ? 100 : Int(usedPercent.rounded(.down))
    }
}

/// One account, as `qota status` prints it.
public nonisolated struct SurfaceAccount: Hashable, Sendable, Identifiable {
    public let id: AccountID
    /// The person's own name for the account.
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
}

/// What the app has written, read whole by a process outside it.
///
/// The `qota` command is a separate process. It cannot see the store, so it sees the files: the
/// catalog for who the accounts are and in what order, and the snapshot book for what each one
/// holds. This is that read, once, into one value.
public nonisolated struct SurfaceReading: Hashable, Sendable {
    /// The accounts, in the person's order.
    public let accounts: [SurfaceAccount]
    /// The instant the files were read.
    public let readAt: Date

    public init(accounts: [SurfaceAccount], readAt: Date) {
        self.accounts = accounts
        self.readAt = readAt
    }

    /// The latest instant any account's numbers were true at.
    public var observedAt: Date? { accounts.compactMap(\.observedAt).max() }

    /// What a read can come back with. Three answers, because a reader shows a different
    /// sentence for each: numbers, "open QotaFolio to add an account", or "cannot read".
    public enum Availability: Sendable {
        case reading(SurfaceReading)
        /// The app has never written a catalog here: it has not run, or it has no accounts yet.
        case noApp
        /// A file is there and this build cannot use it.
        case unreadable
    }

    /// One read of the app's files in `container`.
    public static func read(
        container: SharedContainer,
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

        let accounts = records
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

        return .reading(SurfaceReading(accounts: accounts, readAt: now))
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
