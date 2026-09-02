import Darwin
import Foundation
import QotaFolioCore

/// The app's own files, on the device: the two history books and the recommendation.
///
/// Built on `CatalogFileIO`'s idiom — a trusted Foundation anchor, then a descriptor-relative
/// `O_NOFOLLOW` / `O_RESOLVE_BENEATH` walk through descendants this app owns, then an atomic
/// rename — and deliberately shorter than it in two places.
///
/// **No device flush.** `CatalogFileIO` calls `F_FULLFSYNC` on the staging file and again on
/// the parent directory, and for the account catalog that is right: a row lost to a power cut
/// costs the user a browser sign-in. History costs nothing. The commit here ends at the
/// rename, which is atomic — no reader ever sees half a book — and the page cache carries the
/// bytes down on the system's own schedule. That turns a blocking wait on the storage
/// controller, several times an hour for as long as the app runs, into a memory write.
///
/// **No proof surface.** `CatalogFileIO` re-verifies the anchor's identity after every step,
/// because a substituted account catalog is a security question. A substituted quota trace is
/// not: the file holds percentages, it is inside this app's own group container, and
/// nothing downstream trusts it with more than a sparkline. The trust flags are kept because
/// they are one flag each and they cost nothing at runtime; the re-walks are not, because
/// they are syscalls buying a proof nobody needs.
nonisolated struct UsageHistoryFileIO: SharedFileAccess {
    private let locationSource: UsageHistoryLocationSource

    /// Production: the App Group's Application Support directory, alongside `catalog.json`, so
    /// "Remove My Data" takes them all without naming any.
    init() {
        locationSource = .production
    }

    /// Probe-only. The root is validated by `CatalogLocation`, and the leaves stay strict
    /// relative descendants of it.
    init(trustedRootForTesting trustedRoot: URL, relativeDirectory: String) throws {
        var locations: [SharedFile: CatalogLocation] = [:]
        for file in SharedFile.allCases {
            locations[file] = try CatalogLocation(
                trustedAnchorURL: trustedRoot,
                relativeCatalogPath: relativeDirectory + "/" + file.leafName
            )
        }
        locationSource = .trustedTemporary(locations)
    }

    func read(_ file: SharedFile) -> UsageHistoryBytes {
        guard let location = try? locationSource.resolve(file) else {
            return .unavailable(.obstructed)
        }

        let directory: Int32
        do {
            directory = try openDirectory(for: location, createMissing: false)
        } catch UsageHistoryIOError.missingDescendant {
            return .unavailable(.absent)
        } catch {
            return .unavailable(.obstructed)
        }
        defer { Darwin.close(directory) }

        let descriptor = withHistoryPathBytes(location.leafName) { leaf in
            retryingHistoryInterrupts {
                Darwin.openat(
                    directory,
                    leaf,
                    O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
                )
            }
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return .unavailable(.absent) }
            // `ELOOP` / `ENOTDIR` / `EMLINK` name the leaf itself: something that is not a
            // file stands where the book belongs. That is a verdict on what is there, so the
            // next flush writes over it. Calling it an obstruction would be a claim about
            // the machine, and it would stop the subsystem writing for as long as the thing
            // stood there.
            if errno == ELOOP || errno == ENOTDIR || errno == EMLINK {
                return .unavailable(.unrecognisedBytes)
            }
            return .unavailable(.obstructed)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { return .unavailable(.obstructed) }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            // Something that is not this app's own regular file stands where the book
            // belongs. A verdict on what is there, not on the machine.
            return .unavailable(.unrecognisedBytes)
        }
        guard status.st_size >= 0, status.st_size <= off_t(file.maximumBytes) else {
            // Larger than anything this build can author. Refused before a byte is allocated.
            return .unavailable(.unrecognisedBytes)
        }

        do {
            return .loaded(try readAll(from: descriptor, upTo: file.maximumBytes))
        } catch UsageHistoryIOError.implausibleSize {
            return .unavailable(.unrecognisedBytes)
        } catch {
            return .unavailable(.obstructed)
        }
    }

    @discardableResult
    func write(_ data: Data, to file: SharedFile) -> Bool {
        guard data.count <= file.maximumBytes,
              let location = try? locationSource.resolve(file) else { return false }

        do {
            let directory = try openDirectory(for: location, createMissing: true)
            defer { Darwin.close(directory) }

            let temporaryName = ".qotafolio-history-\(UUID().uuidString).tmp"
            var temporaryExists = false
            defer {
                if temporaryExists {
                    withHistoryPathBytes(temporaryName) { name in
                        _ = Darwin.unlinkat(directory, name, 0)
                    }
                }
            }

            let temporary = withHistoryPathBytes(temporaryName) { name in
                retryingHistoryInterrupts {
                    Darwin.openat(
                        directory,
                        name,
                        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
                            | O_RESOLVE_BENEATH,
                        mode_t(S_IRUSR | S_IWUSR)
                    )
                }
            }
            guard temporary >= 0 else { throw historyError() }
            temporaryExists = true
            defer { Darwin.close(temporary) }

            try writeAll(data, to: temporary)

            // The commit. Atomic by rename, and that is where it ends: no `F_FULLFSYNC` on
            // the file and none on the directory. See this type's note.
            let renamed = withHistoryPathBytes(temporaryName) { source in
                withHistoryPathBytes(location.leafName) { leaf in
                    Darwin.renameatx_np(
                        directory,
                        source,
                        directory,
                        leaf,
                        UInt32(RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
                    )
                }
            }
            guard renamed == 0 else { throw historyError() }
            temporaryExists = false
            return true
        } catch {
            return false
        }
    }

    // MARK: - The walk

    private func openDirectory(
        for location: CatalogLocation,
        createMissing: Bool
    ) throws -> Int32 {
        var current = withHistoryPathBytes(location.trustedAnchorURL.path) { path in
            retryingHistoryInterrupts {
                Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            }
        }
        guard current >= 0 else { throw historyError() }

        do {
            for component in location.directoryComponents {
                var next = withHistoryPathBytes(component) { name in
                    retryingHistoryInterrupts {
                        Darwin.openat(
                            current,
                            name,
                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_RESOLVE_BENEATH
                        )
                    }
                }

                if next < 0, errno == ENOENT {
                    guard createMissing else { throw UsageHistoryIOError.missingDescendant }
                    let created = withHistoryPathBytes(component) { name in
                        Darwin.mkdirat(current, name, mode_t(S_IRWXU))
                    }
                    if created != 0, errno != EEXIST { throw historyError() }
                    next = withHistoryPathBytes(component) { name in
                        retryingHistoryInterrupts {
                            Darwin.openat(
                                current,
                                name,
                                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                                    | O_RESOLVE_BENEATH
                            )
                        }
                    }
                }
                guard next >= 0 else { throw historyError() }

                var status = stat()
                guard Darwin.fstat(next, &status) == 0 else {
                    let code = errno
                    Darwin.close(next)
                    throw UsageHistoryIOError.system(code)
                }
                guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                      status.st_uid == geteuid() else {
                    Darwin.close(next)
                    throw UsageHistoryIOError.untrustedAnchor
                }

                Darwin.close(current)
                current = next
            }
            return current
        } catch {
            Darwin.close(current)
            throw error
        }
    }

    private func readAll(from descriptor: Int32, upTo limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                retryingHistoryInterrupts {
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
            }
            guard count >= 0 else { throw historyError() }
            if count == 0 { return data }
            guard data.count + count <= limit else {
                throw UsageHistoryIOError.implausibleSize
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard var address = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = retryingHistoryInterrupts {
                    Darwin.write(descriptor, address, remaining)
                }
                guard count > 0 else { throw historyError() }
                remaining -= count
                address = address.advanced(by: count)
            }
        }
    }
}

// MARK: - Where the files live

private nonisolated enum UsageHistoryLocationSource: Sendable {
    case production
    case trustedTemporary([SharedFile: CatalogLocation])

    func resolve(_ file: SharedFile) throws -> CatalogLocation {
        switch self {
        case .production:
            return try Self.productionLocation(file)
        case .trustedTemporary(let locations):
            guard let location = locations[file] else {
                throw UsageHistoryIOError.untrustedAnchor
            }
            return location
        }
    }

    /// The same derivation `FileCatalogStore` uses, for the same reason: the two books sit
    /// beside `catalog.json` in the App Group container, so the widget and the `qota` command
    /// read the app's samples without asking the app for them, and one removal takes all four
    /// files without naming any of them.
    private static func productionLocation(_ file: SharedFile) throws -> CatalogLocation {
        let container: SharedContainer
        do {
            container = try SharedContainer.resolve()
        } catch {
            throw UsageHistoryIOError.untrustedAnchor
        }

        return try CatalogLocation(
            trustedAnchorURL: container.applicationSupportURL,
            relativeCatalogPath: SharedContainer.relativePath(for: file)
        )
    }
}

// MARK: - Composition

extension UsageHistory {
    /// The history subsystem as the app runs it.
    ///
    /// Two calls to wire: `restoreSnapshots()` at start, `record(_:for:)` after every
    /// successful poll. `forget(_:)` at Remove is a third and worth making.
    public static func live() -> UsageHistory {
        UsageHistory(
            files: UsageHistoryFileIO(),
            assessor: FleetBrain(),
            sentences: AssessmentSentences.recommendation
        )
    }
}

// MARK: - Primitives

private nonisolated enum UsageHistoryIOError: Error, Sendable {
    case missingDescendant
    case untrustedAnchor
    case implausibleSize
    case system(Int32)
}

private nonisolated func historyError() -> UsageHistoryIOError {
    .system(errno)
}

private nonisolated func retryingHistoryInterrupts<T: FixedWidthInteger>(
    _ operation: () -> T
) -> T {
    while true {
        let result = operation()
        if result == -1, errno == EINTR { continue }
        return result
    }
}

private nonisolated func withHistoryPathBytes<T>(
    _ value: String,
    _ body: (UnsafePointer<CChar>) throws -> T
) rethrows -> T {
    try value.withCString(body)
}
