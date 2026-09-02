import Foundation

import QotaFolioCore

public nonisolated enum CatalogWriteCommitDisposition: Equatable, Sendable {
    case notReplaced
    case replacementDurabilityUncertain
}

public nonisolated struct CatalogWriteFailure: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let disposition: CatalogWriteCommitDisposition

    public init(
        disposition: CatalogWriteCommitDisposition,
        underlying _: any Error
    ) {
        self.disposition = disposition
    }

    public var description: String {
        switch disposition {
        case .notReplaced:
            "catalog replacement did not occur"
        case .replacementDurabilityUncertain:
            "catalog replacement durability is uncertain"
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

public nonisolated protocol AccountCatalogPersisting: Sendable {
    func load() -> CatalogLoadResult
    func save(_ records: [AccountRecord]) throws(CatalogPersistenceError)
}

public nonisolated struct FileCatalogStore: AccountCatalogPersisting {
    public let url: URL
    private let locationSource: CatalogLocationSource
    private let fileIO: CatalogFileIO

    // Production callers pass the URL returned by `defaultURL()`. The store
    // independently re-derives the sanctioned Application Support anchor and
    // rejects every other caller-supplied location.
    public init(url: URL) {
        self.init(url: url, fileIO: .live)
    }

    init(url: URL, fileIO: CatalogFileIO) {
        self.url = url
        self.locationSource = .production(requestedURL: url)
        self.fileIO = fileIO
    }

    // Probe-only construction makes trust explicit. The root is opened directly
    // and validated; the catalog path must remain a strict relative descendant.
    init(
        trustedRootForTesting trustedRoot: URL,
        relativeCatalogPath: String,
        fileIO: CatalogFileIO = .live
    ) throws {
        let location = try CatalogLocation(
            trustedAnchorURL: trustedRoot,
            relativeCatalogPath: relativeCatalogPath
        )
        self.url = location.url
        self.locationSource = .trustedTemporary(location)
        self.fileIO = fileIO
    }

    public static func defaultURL() throws -> URL {
        try productionLocation(requestedURL: nil).url
    }

    /// One attempt, reported at full fidelity.
    ///
    /// `CatalogFileIO` computes four outcomes and separates resource exhaustion from tampering.
    /// The map below is one-to-one, so there is nowhere for a collapse to hide: each file-level
    /// outcome has exactly one load-level counterpart, and the obstruction the reader observed is
    /// carried through rather than discarded.
    public func load() -> CatalogLoadResult {
        let location: CatalogLocation
        do {
            location = try locationSource.resolve()
        } catch {
            // The catalog's location could not be derived, or it is not the location the
            // uninstall manifest declares. That is a fault in the environment this build
            // is running in. No file was opened, so the catalog is accused of nothing.
            return .temporarilyUnreadable(.anchorUnusable)
        }

        switch fileIO.readCatalog(at: location) {
        case .missing:
            return .missing
        case .loaded(let data):
            return AccountCatalogCodec.decode(data)
        case .corrupt:
            return .corrupt
        case .obstructed(let obstruction):
            return .temporarilyUnreadable(obstruction)
        }
    }

    public func save(_ records: [AccountRecord]) throws(CatalogPersistenceError) {
        let data: Data
        do {
            data = try AccountCatalogCodec.encode(records)
        } catch {
            throw .encoding(error)
        }

        // The reader refuses a catalog larger than `maximumCatalogBytes` as corrupt.
        // Applying the same bound here is what keeps that safe: the store never
        // authors bytes it would later refuse to read. The refusal happens before
        // the leaf is touched, so the disposition is truthfully `.notReplaced` and
        // the previous catalog is provably intact.
        guard data.count <= CatalogFileIO.maximumCatalogBytes else {
            throw .write(
                CatalogWriteFailure(
                    disposition: .notReplaced,
                    underlying: CatalogFileIOError.implausibleSize
                )
            )
        }

        let location: CatalogLocation
        do {
            location = try locationSource.resolve()
        } catch {
            throw .write(
                CatalogWriteFailure(
                    disposition: .notReplaced,
                    underlying: error
                )
            )
        }

        switch fileIO.writeCatalog(data, to: location) {
        case .committed:
            return
        case .notReplaced(let error):
            throw .write(
                CatalogWriteFailure(
                    disposition: .notReplaced,
                    underlying: error
                )
            )
        case .replacementDurabilityUncertain(let error):
            throw .write(
                CatalogWriteFailure(
                    disposition: .replacementDurabilityUncertain,
                    underlying: error
                )
            )
        }
    }

    fileprivate static func productionLocation(requestedURL: URL?) throws -> CatalogLocation {
        // The App Group container, not this app's own. The panel, the widget extension and
        // the `qota` command are separate processes and none of them can open a sandbox
        // container that is not theirs; every one of them can open this.
        //
        // `SharedContainer` resolves the same directory two ways — `containerManagerd` for a
        // sandboxed process, the path it hands out for anything else. Both branches name one
        // directory, and the group identifier is derived from the bundle identifier, so a
        // development build cannot reach the shipping app's files.
        let container = try SharedContainer.resolve()

        let location = try CatalogLocation(
            trustedAnchorURL: container.applicationSupportURL,
            relativeCatalogPath: SharedContainer.relativePath(for: .catalog)
        )

        if let requestedURL {
            guard requestedURL.isFileURL,
                  requestedURL.standardizedFileURL.path == requestedURL.path,
                  requestedURL.path == location.url.path else {
                throw CatalogFileIOError.invalidLocation
            }
        }
        return location
    }
}

private nonisolated enum CatalogLocationSource: Sendable {
    case production(requestedURL: URL)
    case trustedTemporary(CatalogLocation)

    func resolve() throws -> CatalogLocation {
        switch self {
        case .production(let requestedURL):
            return try FileCatalogStore.productionLocation(requestedURL: requestedURL)
        case .trustedTemporary(let location):
            return location
        }
    }
}
