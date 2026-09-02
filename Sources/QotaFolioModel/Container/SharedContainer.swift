import Foundation

/// The four files this app writes, in the one place everything that reads them can reach.
///
/// The panel, the widget extension, the menu-bar Control and the `qota` command are separate
/// processes, and a separate process cannot open another's sandbox container. An App Group
/// container can be reached by every process signed into the group, so that is where the files
/// live.
public nonisolated enum SharedFile: String, CaseIterable, Sendable {
    /// The accounts: names, providers, order. No secrets — those are in the Keychain.
    case catalog
    /// The last successful poll per account, so a relaunch opens full.
    case snapshots
    /// The sample rings and the completed-window ledger.
    case traces
    /// What the brain decided, and the sentences that say it. Written by the app; read by
    /// `qota which` without linking a line of the app's policy.
    case recommendation

    /// One spelling per file, and the two history books keep theirs.
    public var leafName: String {
        switch self {
        case .catalog: "catalog.json"
        case .snapshots: UsageHistoryFile.snapshots.leafName
        case .traces: UsageHistoryFile.traces.leafName
        case .recommendation: "recommendation.json"
        }
    }

    /// The most this build will read, so nothing allocates a file it would then refuse. Each
    /// number is the one its own reader applies.
    public var maximumBytes: Int {
        switch self {
        case .catalog: AccountCatalogCodec.maximumBytes
        case .snapshots: UsageHistoryFile.snapshots.maximumBytes
        case .traces: UsageHistoryFile.traces.maximumBytes
        case .recommendation: RecommendationDocument.maximumBytes
        }
    }
}

/// Where the four files are, resolved once for whoever is asking.
///
/// **Two ways to the same directory, and that is the point.** A sandboxed process asks
/// `containerManagerd` through `containerURL(forSecurityApplicationGroupIdentifier:)`, which
/// is also what creates the container and its `Library` tree. A process that is not sandboxed
/// — a test, or `qota` run from a shell — gets `nil` from that call and takes the path
/// directly. The path is not a guess: it is the one `containerManagerd` hands out, so both
/// branches name the same bytes on the same disk. The old derivation had to guard against
/// `ENABLE_APP_SANDBOX` going missing and Foundation quietly answering `~/Library/Application
/// Support` instead of the container; here there is no second answer to guard against.
///
/// **The group identifier carries the team prefix.** macOS requires `TEAMID.group.…` on this
/// platform, and the plain `group.…` form resolves to a container root the system treats as
/// protected. `AppIdentity.appGroupIdentifier` spells it, once.
public nonisolated struct SharedContainer: Equatable, Sendable {
    /// The directory the four files sit in, under `Library/Application Support`. Not the
    /// bundle identifier: the group identifier already carries that, and this is a path a
    /// person types into Terminal.
    public static let ownedDirectoryName = "QotaFolio"

    public enum ResolutionError: Error, Equatable, Sendable {
        /// The group container could neither be reached nor created. Either this build is not
        /// signed with `com.apple.security.application-groups`, or its entitlement names a
        /// different group from the one `AppIdentity` derives.
        case groupContainerUnavailable
    }

    /// `~/Library/Group Containers/<group>` — what `containerURL(…)` answers.
    public let rootURL: URL

    /// `<group>/Library/Application Support` — the trusted anchor the file stores walk from.
    /// `containerManagerd` creates this for a sandboxed process; this type creates it for
    /// everyone else.
    public let applicationSupportURL: URL

    /// `<group>/Library/Application Support/QotaFolio` — where the four files live.
    public let directoryURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        applicationSupportURL = self.rootURL
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        directoryURL = applicationSupportURL
            .appending(path: Self.ownedDirectoryName, directoryHint: .isDirectory)
    }

    public func url(for file: SharedFile) -> URL {
        directoryURL.appending(path: file.leafName, directoryHint: .notDirectory)
    }

    /// The path a file store hands `CatalogLocation`: relative to `applicationSupportURL`.
    public static func relativePath(for file: SharedFile) -> String {
        "\(ownedDirectoryName)/\(file.leafName)"
    }

    /// This process's group container, with its `Library/Application Support` in place.
    ///
    /// `create` exists because a reader has no business making directories: `qota status`
    /// asking where the files are should not leave a tree behind when the app has never run.
    /// The app's own stores pass `true`, once, at the point they would have created it anyway.
    public static func resolve(
        identity: AppIdentity = .current,
        fileManager: FileManager = .default,
        create: Bool = true
    ) throws -> SharedContainer {
        let container = SharedContainer(rootURL: try groupRootURL(
            identity: identity,
            fileManager: fileManager
        ))

        if create {
            do {
                try fileManager.createDirectory(
                    at: container.applicationSupportURL,
                    withIntermediateDirectories: true
                )
            } catch {
                throw ResolutionError.groupContainerUnavailable
            }
        }
        return container
    }

    private static func groupRootURL(
        identity: AppIdentity,
        fileManager: FileManager
    ) throws -> URL {
        if let url = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: identity.appGroupIdentifier
        ) {
            // The one thing worth checking: that the answer is this group's container and not
            // some other directory. A mismatch means the entitlement and `AppIdentity` have
            // drifted apart, and the app would otherwise write its files somewhere nothing
            // reads them, silently.
            guard url.standardizedFileURL.lastPathComponent == identity.appGroupIdentifier else {
                throw ResolutionError.groupContainerUnavailable
            }
            return url
        }

        // Not sandboxed into the group. `NSHomeDirectory()` is the real home here — inside a
        // sandbox it would be the container's `Data` directory, which is exactly why the call
        // above comes first.
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(
                path: "Library/Group Containers/\(identity.appGroupIdentifier)",
                directoryHint: .isDirectory
            )
    }
}

extension UsageHistoryFile {
    /// Which of the four shared files this book is. One direction of a pair that has to
    /// agree: `SharedFile.leafName` takes its two history spellings from here.
    public var sharedFile: SharedFile {
        switch self {
        case .snapshots: .snapshots
        case .traces: .traces
        }
    }
}

/// Where this app's files live and how they are read and written.
///
/// One protocol with two synchronous methods, because both are called from inside an actor
/// with its own serial queue and a synchronous `nonisolated` call runs on its caller's
/// executor. The production conformance is `UsageHistoryFileIO`; a test supplies its own and
/// gets to be a filesystem that is absent, obstructed, truncated, or from the future.
///
/// It speaks `SharedFile` rather than `UsageHistoryFile` because `recommendation.json` is
/// written by the same actor on the same clock as the snapshot book, and a second seam for
/// one more file in the same directory would be a second thing to keep in step.
public nonisolated protocol SharedFileAccess: Sendable {
    func read(_ file: SharedFile) -> UsageHistoryBytes
    /// `false` says the bytes did not land. Nothing in the app behaves differently for it —
    /// a lost sample is a lost sample and the next flush writes the whole book again. It is
    /// returned so a test can prove a write happened and a log line can say when one did not.
    @discardableResult
    func write(_ data: Data, to file: SharedFile) -> Bool
}
