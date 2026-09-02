import Foundation

/// The one-time move of the installed app's three files into the App Group container.
///
/// A user who updates from a build that kept its files inside its own sandbox container has
/// two connected accounts, a week of samples and a ledger of completed windows sitting where
/// the new build no longer looks. This copies them across, on the first launch that finds
/// them, and the user notices nothing — which is the whole requirement.
///
/// **Three properties, and the order of the copies is what buys the last two.**
///
/// - *Verify, then adopt.* Every file is decoded before it is left in place. A catalog the
///   new build would call corrupt is a catalog that quarantines the app and tells the user
///   their account list is broken; copying one across would turn a working install into that.
///   A file that does not decode is not left behind, and the app starts where a fresh install
///   starts.
/// - *The catalog goes last, and its presence is the marker.* A migration that is interrupted
///   — a crash, a power cut, a Force Quit — leaves the group catalog absent, so the next
///   launch runs the whole thing again from the originals. There is no half-migrated state
///   and no flag file to get out of step with the files it describes.
/// - *The originals stay.* Downgrading to the previous build must keep working, and a user
///   who does that has lost nothing. macOS reaps the old container when the app is removed.
public nonisolated enum SharedContainerMigration {
    public struct Outcome: Equatable, Sendable {
        /// Nothing to do: either the group already holds a catalog, or the old container
        /// never did. The overwhelmingly common answer, on every launch after the first.
        public static let notNeeded = Outcome(adopted: [], refused: [], failed: false)

        /// The files now in the group container that were not there before.
        public let adopted: [SharedFile]
        /// The files that were read, did not decode, and were left where they were.
        public let refused: [SharedFile]
        /// The old container held a catalog and this could not put it in the group. The app
        /// starts as a fresh install; the originals are untouched and the next launch tries
        /// again.
        public let failed: Bool

        public init(adopted: [SharedFile], refused: [SharedFile], failed: Bool) {
            self.adopted = adopted
            self.refused = refused
            self.failed = failed
        }

        /// Whether this launch moved anything. What decides if there is a line worth logging.
        public var ran: Bool { !adopted.isEmpty || !refused.isEmpty || failed }
    }

    /// The three files that predate the group container, catalog last. `recommendation.json`
    /// is new, so there is never one to move.
    public static let movedFiles: [SharedFile] = [.snapshots, .traces, .catalog]

    /// This process's own migration: resolve both directories, then run.
    public static func runIfNeeded(
        identity: AppIdentity = .current,
        fileManager: FileManager = .default
    ) -> Outcome {
        guard let container = try? SharedContainer.resolve(
            identity: identity,
            fileManager: fileManager,
            create: false
        ) else {
            // No group container at all. Either the entitlement is missing or it names a
            // different group; the app has a larger problem than a migration, and its own
            // file stores are the ones that report it.
            return .notNeeded
        }
        return run(
            from: oldContainerDirectory(identity: identity),
            into: container,
            fileManager: fileManager
        )
    }

    /// The migration itself, over two directories it is handed.
    ///
    /// Separated from `runIfNeeded` because the code that moves a user's accounts has to be
    /// testable without a user's accounts — the same reason `Uninstall` takes its data
    /// directory as a seam.
    public static func run(
        from oldDirectory: URL?,
        into container: SharedContainer,
        fileManager: FileManager = .default
    ) -> Outcome {
        // The marker. A group catalog means a previous launch already finished this.
        guard !fileManager.fileExists(atPath: container.url(for: .catalog).path) else {
            return .notNeeded
        }

        guard let oldDirectory,
              fileManager.fileExists(
                  atPath: oldDirectory.appending(
                      path: SharedFile.catalog.leafName,
                      directoryHint: .notDirectory
                  ).path
              ) else {
            // Nothing to move: a fresh install, or a build that was already writing to the
            // group when it last ran.
            return .notNeeded
        }

        do {
            try fileManager.createDirectory(
                at: container.directoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            return Outcome(adopted: [], refused: [], failed: true)
        }

        var adopted: [SharedFile] = []
        var refused: [SharedFile] = []

        for file in movedFiles {
            switch copy(file, from: oldDirectory, to: container, fileManager: fileManager) {
            case .adopted: adopted.append(file)
            case .refused: refused.append(file)
            case .absent: continue
            }
        }

        return Outcome(
            adopted: adopted,
            refused: refused,
            // The catalog is the one file whose absence the user would see, so it is the one
            // whose failure is worth the name. The two books are a convenience: an app that
            // starts without them polls and fills them again within the hour.
            failed: !adopted.contains(.catalog)
        )
    }

    private enum CopyResult { case adopted, refused, absent }

    private static func copy(
        _ file: SharedFile,
        from oldDirectory: URL,
        to container: SharedContainer,
        fileManager: FileManager
    ) -> CopyResult {
        let source = oldDirectory.appending(path: file.leafName, directoryHint: .notDirectory)
        guard fileManager.fileExists(atPath: source.path) else { return .absent }

        // The size before the bytes, so a file larger than anything this build would read is
        // refused without being allocated. The same bound each file's own reader applies.
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        guard let size, size <= file.maximumBytes else { return .refused }

        guard let data = try? Data(contentsOf: source, options: [.uncached]),
              decodes(data, as: file) else {
            return .refused
        }

        do {
            try data.write(to: container.url(for: file), options: [.atomic])
            return .adopted
        } catch {
            return .refused
        }
    }

    /// The same reader each file's own subsystem uses, so "it decoded" here means the app
    /// will read it there.
    private static func decodes(_ data: Data, as file: SharedFile) -> Bool {
        switch file {
        case .catalog:
            guard case .loaded = AccountCatalogCodec.decode(data) else { return false }
            return true
        case .snapshots:
            guard case .loaded = UsageHistoryCodec.decode(data, as: UsageSnapshotBook.self) else {
                return false
            }
            return true
        case .traces:
            guard case .loaded = UsageHistoryCodec.decode(data, as: UsageTraceBook.self) else {
                return false
            }
            return true
        case .recommendation:
            return RecommendationCodec.decode(data) != nil
        }
    }

    /// Where the previous build kept them: this app's own sandbox container, under its bundle
    /// identifier. `nil` when this process is not running out of one, which is every test and
    /// the `qota` command.
    public static func oldContainerDirectory(identity: AppIdentity) -> URL? {
        guard let data = try? OwnedContainerDataDirectory.resolve() else { return nil }
        return URL(
            fileURLWithPath: AppIdentityLocations(
                identity: identity,
                dataDirectoryPath: data.path
            ).applicationSupportDirectoryPath,
            isDirectory: true
        )
    }
}
