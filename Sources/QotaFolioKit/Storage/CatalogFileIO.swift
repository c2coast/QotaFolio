import Darwin
import Foundation
import QotaFolioCore

// `.missing` is emitted only after a trusted anchor has been opened and a
// descriptor-relative, no-follow lookup proves that an owned descendant or the
// catalog leaf is absent. Suspicious identities remain quarantined.
//
// The two failure cases answer two different questions, and keeping them apart is the
// whole reason this type exists rather than a `Data?`:
//
// - `.corrupt` is a verdict ON THE LEAF. Its bytes or its identity are wrong, and reading
//   them again cannot change that. Recovery — quarantine, and telling the user their
//   catalog is broken — acts on the data, so it may only be reached from here.
// - `.obstructed` says the read DID NOT HAPPEN. The reader learned nothing about the leaf,
//   so it says nothing about it. The obstruction names what it did observe: a resource it
//   could not get, or a directory it may not use.
nonisolated enum CatalogFileReadResult: Sendable {
    case missing
    case loaded(Data)
    case corrupt
    case obstructed(CatalogReadObstruction)
}

nonisolated enum CatalogFileIOError: Error, Sendable {
    case invalidLocation
    case missingDescendant
    // The DIRECTORY chain is not one this build may use: an anchor or an owned descendant
    // with the wrong mode, the wrong owner, a symlink on the path, or an identity that
    // changed under us. Separate from `untrustedIdentity` because it is an environment
    // fault: the catalog leaf is never examined, so calling it corrupt blames the data for
    // a directory's permissions.
    case untrustedAnchor
    // The LEAF is not the object it must be: wrong kind, wrong owner, linked more than
    // once, group- or world-writable, or a different inode than the one just written.
    case untrustedIdentity
    case implausibleSize
    case system(Int32)
}

nonisolated enum CatalogFileCommitOutcome {
    case notReplaced(any Error)
    case committed
    case replacementDurabilityUncertain(any Error)
}

nonisolated enum CatalogFileWriteCheckpoint: Equatable, Sendable {
    case beforeAtomicReplacement
    case afterAtomicReplacementBeforeParentSync
}

nonisolated struct CatalogLocation: Sendable {
    let trustedAnchorURL: URL
    let directoryComponents: [String]
    let leafName: String
    let url: URL

    init(trustedAnchorURL: URL, relativeCatalogPath: String) throws {
        guard trustedAnchorURL.isFileURL,
              trustedAnchorURL.standardizedFileURL.path == trustedAnchorURL.path,
              trustedAnchorURL.path.first == "/",
              !trustedAnchorURL.path.utf8.contains(0),
              !relativeCatalogPath.isEmpty,
              relativeCatalogPath.first != "/",
              !relativeCatalogPath.utf8.contains(0) else {
            throw CatalogFileIOError.invalidLocation
        }

        let components = relativeCatalogPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && !component.contains("/")
                      && !component.utf8.contains(0)
              }),
              let leafName = components.last else {
            throw CatalogFileIOError.invalidLocation
        }

        var catalogURL = trustedAnchorURL
        for component in components {
            catalogURL.appendPathComponent(component, isDirectory: false)
        }
        guard catalogURL.standardizedFileURL.path == catalogURL.path else {
            throw CatalogFileIOError.invalidLocation
        }

        self.trustedAnchorURL = trustedAnchorURL
        self.directoryComponents = Array(components.dropLast())
        self.leafName = leafName
        self.url = catalogURL
    }
}

nonisolated struct CatalogFileIO: Sendable {
    /// The bound the reader applies, spelled once in `AccountCatalogCodec` where the file
    /// format is. Kept as a name here because this is the type that enforces it.
    static var maximumCatalogBytes: Int { AccountCatalogCodec.maximumBytes }

    typealias ReadOpenObserver = @Sendable () -> Void
    typealias DirectorySynchronizer = @Sendable (Int32) throws -> Void
    typealias WriteCheckpointObserver = @Sendable (CatalogFileWriteCheckpoint) throws -> Void

    private let readOpenObserver: ReadOpenObserver
    private let directorySynchronizer: DirectorySynchronizer
    private let writeCheckpointObserver: WriteCheckpointObserver

    static var live: Self {
        Self(
            readOpenObserver: {},
            directorySynchronizer: { descriptor in
                try fullSynchronizeDirectory(descriptor)
            },
            writeCheckpointObserver: { _ in }
        )
    }

    init(
        readOpenObserver: @escaping ReadOpenObserver = {},
        directorySynchronizer: @escaping DirectorySynchronizer = { descriptor in
            try fullSynchronizeDirectory(descriptor)
        },
        writeCheckpointObserver: @escaping WriteCheckpointObserver = { _ in }
    ) {
        self.readOpenObserver = readOpenObserver
        self.directorySynchronizer = directorySynchronizer
        self.writeCheckpointObserver = writeCheckpointObserver
    }

    func readCatalog(at location: CatalogLocation) -> CatalogFileReadResult {
        let directory: DirectoryAnchor
        do {
            directory = try openDirectory(for: location, createMissing: false)
        } catch CatalogFileIOError.missingDescendant {
            return .missing
        } catch {
            // The leaf was never opened, so no verdict about it is available. What went
            // wrong with the DIRECTORY is, and that is what gets reported.
            return .obstructed(directoryObstruction(for: error))
        }
        defer { Darwin.close(directory.descriptor) }

        var pathStatus = stat()
        let pathResult = withPathBytes(location.leafName) { leaf in
            Darwin.fstatat(
                directory.descriptor,
                leaf,
                &pathStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard pathResult == 0 else {
            if errno == ENOENT { return .missing }
            // `ELOOP`/`ENOTDIR`/`EMLINK` here name the leaf itself: something stands where
            // the catalog file must be. That is a verdict on the leaf, not on the anchor.
            if isUntrustedPathError(errno) { return .corrupt }
            return .obstructed(.resourcesUnavailable)
        }
        guard trustedCatalogFile(pathStatus) else { return .corrupt }

        let fileDescriptor = withPathBytes(location.leafName) { leaf in
            retryingInterrupts {
                Darwin.openat(
                    directory.descriptor,
                    leaf,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH | O_UNIQUE
                )
            }
        }
        guard fileDescriptor >= 0 else {
            if isResourceError(errno) { return .obstructed(.resourcesUnavailable) }
            return .corrupt
        }
        defer { Darwin.close(fileDescriptor) }

        var openedStatus = stat()
        guard Darwin.fstat(fileDescriptor, &openedStatus) == 0 else {
            return .obstructed(.resourcesUnavailable)
        }
        guard trustedCatalogFile(openedStatus),
              sameObject(pathStatus, openedStatus),
              plausibleCatalogSize(openedStatus.st_size) else {
            return .corrupt
        }

        readOpenObserver()

        // The size that satisfied the guard above belongs to the object this
        // descriptor names, and it was read before a byte was allocated. `readAll`
        // re-applies the same bound as it goes, so a leaf that grows after the
        // guard is refused rather than allocated.
        let data: Data
        do {
            data = try readAll(from: fileDescriptor, upTo: Self.maximumCatalogBytes)
        } catch CatalogFileIOError.implausibleSize {
            return .corrupt
        } catch {
            // `read(2)` refused. The bytes on the device are not accused of anything.
            return .obstructed(.resourcesUnavailable)
        }

        var completedStatus = stat()
        guard Darwin.fstat(fileDescriptor, &completedStatus) == 0 else {
            return .obstructed(.resourcesUnavailable)
        }
        guard stableDuringRead(openedStatus, completedStatus),
              completedStatus.st_size >= 0,
              UInt64(completedStatus.st_size) == UInt64(data.count) else {
            return .corrupt
        }

        var currentPathStatus = stat()
        let currentPathResult = withPathBytes(location.leafName) { leaf in
            Darwin.fstatat(
                directory.descriptor,
                leaf,
                &currentPathStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard currentPathResult == 0,
              trustedCatalogFile(currentPathStatus),
              sameObject(openedStatus, currentPathStatus) else {
            return .corrupt
        }

        do {
            try verifyDirectoryAnchor(directory, for: location)
        } catch {
            return .obstructed(directoryObstruction(for: error))
        }

        return .loaded(data)
    }

    func writeCatalog(_ data: Data, to location: CatalogLocation) -> CatalogFileCommitOutcome {
        // Commit boundary: same-directory 0600 temp → full media flush →
        // descriptor-relative atomic rename → full parent-directory media flush.
        // A failure before rename proves the old pathname still names the old object.
        // A failure after rename cannot truthfully claim rollback: the replacement is
        // visible now, but a power loss may recover either directory entry.
        var replacementOccurred = false

        do {
            let directory = try openDirectory(for: location, createMissing: true)
            defer { Darwin.close(directory.descriptor) }

            try verifyDirectoryAnchor(directory, for: location)
            try verifyReplaceableLeaf(location.leafName, in: directory.descriptor)

            let temporaryName = ".qotafolio-catalog-\(UUID().uuidString).tmp"
            var temporaryExists = false
            defer {
                if temporaryExists {
                    withPathBytes(temporaryName) { name in
                        _ = Darwin.unlinkat(directory.descriptor, name, 0)
                    }
                }
            }

            let temporaryDescriptor = withPathBytes(temporaryName) { name in
                retryingInterrupts {
                    Darwin.openat(
                        directory.descriptor,
                        name,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
                            | O_RESOLVE_BENEATH | O_UNIQUE,
                        mode_t(S_IRUSR | S_IWUSR)
                    )
                }
            }
            guard temporaryDescriptor >= 0 else { throw systemError() }
            temporaryExists = true
            defer { Darwin.close(temporaryDescriptor) }

            guard Darwin.fchmod(temporaryDescriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw systemError()
            }
            try writeAll(data, to: temporaryDescriptor)
            try Self.fullSynchronize(temporaryDescriptor)

            var temporaryStatus = stat()
            guard Darwin.fstat(temporaryDescriptor, &temporaryStatus) == 0 else {
                throw systemError()
            }
            guard trustedCatalogFile(temporaryStatus),
                  temporaryStatus.st_size >= 0,
                  UInt64(temporaryStatus.st_size) == UInt64(data.count) else {
                throw CatalogFileIOError.untrustedIdentity
            }

            try verifyDirectoryAnchor(directory, for: location)
            try verifyReplaceableLeaf(location.leafName, in: directory.descriptor)
            try writeCheckpointObserver(.beforeAtomicReplacement)

            let renameResult = withPathBytes(temporaryName) { temporary in
                withPathBytes(location.leafName) { leaf in
                    Darwin.renameatx_np(
                        directory.descriptor,
                        temporary,
                        directory.descriptor,
                        leaf,
                        UInt32(RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
                    )
                }
            }
            guard renameResult == 0 else { throw systemError() }
            replacementOccurred = true
            temporaryExists = false

            try writeCheckpointObserver(.afterAtomicReplacementBeforeParentSync)

            var committedStatus = stat()
            let committedResult = withPathBytes(location.leafName) { leaf in
                Darwin.fstatat(
                    directory.descriptor,
                    leaf,
                    &committedStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard committedResult == 0,
                  trustedCatalogFile(committedStatus),
                  sameObject(temporaryStatus, committedStatus) else {
                throw CatalogFileIOError.untrustedIdentity
            }
            try verifyDirectoryAnchor(directory, for: location)

            try directorySynchronizer(directory.descriptor)

            var durableStatus = stat()
            let durableResult = withPathBytes(location.leafName) { leaf in
                Darwin.fstatat(
                    directory.descriptor,
                    leaf,
                    &durableStatus,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard durableResult == 0,
                  trustedCatalogFile(durableStatus),
                  sameObject(temporaryStatus, durableStatus) else {
                throw CatalogFileIOError.untrustedIdentity
            }
            try verifyDirectoryAnchor(directory, for: location)
            return .committed
        } catch {
            if replacementOccurred {
                return .replacementDurabilityUncertain(error)
            }
            return .notReplaced(error)
        }
    }

    private static func fullSynchronize(_ descriptor: Int32) throws {
        guard retryingInterrupts({ Darwin.fcntl(descriptor, F_FULLFSYNC) }) == 0 else {
            throw systemError()
        }
    }

    // A directory barrier answers a capability question as well as an I/O one.
    // `ENOTSUP` / `EOPNOTSUPP` / `EINVAL` / `ENOTTY` say this volume implements no
    // barrier stronger than the rename that already succeeded and was already
    // verified by inode. Reporting that as durability uncertainty makes every
    // successful save on such a volume look like a failed one, which quarantines
    // the catalog and shows the user zero accounts. The commit is visible and the
    // platform has given everything it has, so the commit model records it as a
    // commit. Every other errno is a real device refusal and still throws.
    private static func fullSynchronizeDirectory(_ descriptor: Int32) throws {
        if retryingInterrupts({ Darwin.fcntl(descriptor, F_FULLFSYNC) }) == 0 { return }
        guard directoryBarrierIsUnsupported(errno) else { throw systemError() }
    }

    // These four codes are the volume answering "I implement no such barrier",
    // not the device answering "the flush failed". Every other code is a refusal.
    static func directoryBarrierIsUnsupported(_ code: Int32) -> Bool {
        code == ENOTSUP || code == EOPNOTSUPP || code == EINVAL || code == ENOTTY
    }

    private func verifyReplaceableLeaf(
        _ leafName: String,
        in directoryDescriptor: Int32
    ) throws {
        var status = stat()
        let result = withPathBytes(leafName) { leaf in
            Darwin.fstatat(
                directoryDescriptor,
                leaf,
                &status,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0 {
            guard trustedCatalogFile(status) else {
                throw CatalogFileIOError.untrustedIdentity
            }
            return
        }
        if errno == ENOENT { return }
        if isUntrustedPathError(errno) {
            throw CatalogFileIOError.untrustedIdentity
        }
        throw systemError()
    }

    private func readAll(from descriptor: Int32, upTo limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                retryingInterrupts {
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
            }
            guard count >= 0 else { throw systemError() }
            if count == 0 { return data }
            guard data.count + Int(count) <= limit else {
                throw CatalogFileIOError.implausibleSize
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var baseAddress = bytes.baseAddress else { return }
            var remaining = bytes.count

            while remaining > 0 {
                let count = retryingInterrupts {
                    Darwin.write(descriptor, baseAddress, remaining)
                }
                guard count > 0 else { throw systemError() }
                remaining -= count
                baseAddress = baseAddress.advanced(by: count)
            }
        }
    }

    private func openDirectory(
        for location: CatalogLocation,
        createMissing: Bool
    ) throws -> DirectoryAnchor {
        // Foundation supplies the trusted sandbox/container anchor. Open that
        // directory in one syscall, then resolve only QotaFolio-owned descendants.
        var currentDescriptor = try openTrustedAnchor(at: location.trustedAnchorURL)
        var identities: [FileIdentity] = []

        do {
            var anchorStatus = stat()
            guard Darwin.fstat(currentDescriptor, &anchorStatus) == 0 else {
                throw systemError()
            }
            guard trustedCatalogDirectory(anchorStatus) else {
                throw CatalogFileIOError.untrustedAnchor
            }
            identities.append(FileIdentity(anchorStatus))

            for component in location.directoryComponents {
                var nextDescriptor = withPathBytes(component) { name in
                    retryingInterrupts {
                        Darwin.openat(
                            currentDescriptor,
                            name,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                                | O_RESOLVE_BENEATH
                        )
                    }
                }

                if nextDescriptor < 0, errno == ENOENT {
                    guard createMissing else {
                        throw CatalogFileIOError.missingDescendant
                    }

                    let createResult = withPathBytes(component) { name in
                        Darwin.mkdirat(currentDescriptor, name, mode_t(S_IRWXU))
                    }
                    if createResult != 0, errno != EEXIST { throw systemError() }

                    nextDescriptor = withPathBytes(component) { name in
                        retryingInterrupts {
                            Darwin.openat(
                                currentDescriptor,
                                name,
                                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                                    | O_RESOLVE_BENEATH
                            )
                        }
                    }
                    if createResult == 0 {
                        guard nextDescriptor >= 0 else { throw systemError() }
                        guard Darwin.fchmod(nextDescriptor, mode_t(S_IRWXU)) == 0 else {
                            let code = errno
                            Darwin.close(nextDescriptor)
                            throw CatalogFileIOError.system(code)
                        }
                        do {
                            try Self.fullSynchronizeDirectory(nextDescriptor)
                            try directorySynchronizer(currentDescriptor)
                        } catch {
                            Darwin.close(nextDescriptor)
                            throw error
                        }
                    }
                }

                guard nextDescriptor >= 0 else {
                    if isUntrustedPathError(errno) {
                        throw CatalogFileIOError.untrustedAnchor
                    }
                    throw systemError()
                }

                var componentStatus = stat()
                guard Darwin.fstat(nextDescriptor, &componentStatus) == 0 else {
                    let code = errno
                    Darwin.close(nextDescriptor)
                    throw CatalogFileIOError.system(code)
                }
                guard trustedCatalogDirectory(componentStatus) else {
                    Darwin.close(nextDescriptor)
                    throw CatalogFileIOError.untrustedAnchor
                }

                identities.append(FileIdentity(componentStatus))
                Darwin.close(currentDescriptor)
                currentDescriptor = nextDescriptor
            }

            return DirectoryAnchor(
                descriptor: currentDescriptor,
                identities: identities
            )
        } catch {
            Darwin.close(currentDescriptor)
            throw error
        }
    }

    private func openTrustedAnchor(at url: URL) throws -> Int32 {
        let descriptor = withPathBytes(url.path) { path in
            retryingInterrupts {
                Darwin.open(
                    path,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
                )
            }
        }
        guard descriptor >= 0 else {
            if isUntrustedPathError(errno) {
                throw CatalogFileIOError.untrustedAnchor
            }
            throw systemError()
        }
        return descriptor
    }

    private func verifyDirectoryAnchor(
        _ expected: DirectoryAnchor,
        for location: CatalogLocation
    ) throws {
        let current = try openDirectory(for: location, createMissing: false)
        defer { Darwin.close(current.descriptor) }
        guard expected.identities == current.identities else {
            throw CatalogFileIOError.untrustedAnchor
        }
    }
}

private nonisolated struct DirectoryAnchor: Sendable {
    let descriptor: Int32
    let identities: [FileIdentity]
}

private nonisolated struct FileIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
    }
}

private nonisolated func trustedCatalogDirectory(_ status: stat) -> Bool {
    let kind = status.st_mode & mode_t(S_IFMT)
    let unsafeWriteBits = mode_t(S_IWGRP | S_IWOTH)
    let specialBits = mode_t(S_ISUID | S_ISGID | S_ISVTX)
    return kind == mode_t(S_IFDIR)
        && status.st_uid == geteuid()
        && status.st_mode & unsafeWriteBits == 0
        && status.st_mode & specialBits == 0
        && status.st_mode & mode_t(S_IRWXU) == mode_t(S_IRWXU)
}

private nonisolated func trustedCatalogFile(_ status: stat) -> Bool {
    let kind = status.st_mode & mode_t(S_IFMT)
    let unsafeWriteBits = mode_t(S_IWGRP | S_IWOTH)
    let specialBits = mode_t(S_ISUID | S_ISGID | S_ISVTX)
    return kind == mode_t(S_IFREG)
        && status.st_uid == geteuid()
        && status.st_nlink == 1
        && status.st_mode & unsafeWriteBits == 0
        && status.st_mode & specialBits == 0
}

private nonisolated func plausibleCatalogSize(_ size: off_t) -> Bool {
    size >= 0 && size <= off_t(CatalogFileIO.maximumCatalogBytes)
}

private nonisolated func sameObject(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
}

private nonisolated func stableDuringRead(_ before: stat, _ after: stat) -> Bool {
    sameObject(before, after)
        && before.st_mode == after.st_mode
        && before.st_uid == after.st_uid
        && before.st_gid == after.st_gid
        && before.st_nlink == after.st_nlink
        && before.st_size == after.st_size
        && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
        && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
        && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        && before.st_gen == after.st_gen
}

private nonisolated func retryingInterrupts<T: FixedWidthInteger>(
    _ operation: () -> T
) -> T {
    while true {
        let result = operation()
        if result == -1, errno == EINTR { continue }
        return result
    }
}

// The string's own UTF-8 bytes, passed through unchanged. This is deliberately not
// `URL.withUnsafeFileSystemRepresentation`, and it does not promise to be: it makes
// no normalisation claim, so no caller can rely on one. What establishes trust here
// is `O_NOFOLLOW_ANY`, `O_RESOLVE_BENEATH` and the identity re-verification after
// every open — never the spelling of a name.
private nonisolated func withPathBytes<T>(
    _ value: String,
    _ body: (UnsafePointer<CChar>) throws -> T
) rethrows -> T {
    try value.withCString(body)
}

private nonisolated func isUntrustedPathError(_ code: Int32) -> Bool {
    code == ELOOP || code == ENOTDIR || code == EMLINK
}

private nonisolated func isResourceError(_ code: Int32) -> Bool {
    code == EMFILE || code == ENFILE || code == ENOMEM
}

// What a failed DIRECTORY operation may honestly say. It is reached only when the catalog
// leaf was never opened, so it never speaks about the leaf; it reports what it did observe.
//
// Two claims are available and only two: "this is not a directory this build may use" and
// "this machine could not do it just now". Trust failures always take the first, never the
// second, so no refactor can quietly turn a rejected identity into a retryable resource
// hiccup. An errno the reader cannot place takes the second, which is the honest default:
// an unclassified failure is exactly the case where nothing about the catalog may be
// asserted, and a later attempt costs nothing.
private nonisolated func directoryObstruction(for error: any Error) -> CatalogReadObstruction {
    guard let ioError = error as? CatalogFileIOError else { return .resourcesUnavailable }
    switch ioError {
    case .invalidLocation, .missingDescendant, .untrustedAnchor,
         .untrustedIdentity, .implausibleSize:
        return .anchorUnusable
    case .system(let code):
        return anchorIsUnusable(code) ? .anchorUnusable : .resourcesUnavailable
    }
}

// The codes that describe the PLACE rather than the moment: it is absent (`ENOENT`), it is
// not a directory (`ENOTDIR`), a symlink stands on the path (`ELOOP`, `EMLINK`), this
// process may not open it (`EACCES`, `EPERM`), it is mounted read-only (`EROFS`), or the
// filesystem will not accept the name (`ENAMETOOLONG`). Descriptors, memory and device
// errors are all the moment, and fall through to the retryable side.
private nonisolated func anchorIsUnusable(_ code: Int32) -> Bool {
    code == ENOENT || code == ENOTDIR || code == ELOOP || code == EMLINK
        || code == EACCES || code == EPERM || code == EROFS || code == ENAMETOOLONG
}

private nonisolated func systemError() -> CatalogFileIOError {
    .system(errno)
}
