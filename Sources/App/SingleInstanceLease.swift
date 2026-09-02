import Darwin
import Dispatch
import Foundation
import QotaFolioCore

/// The identity of the exact file object a lease was granted on.
///
/// A held descriptor keeps working after its name is unlinked, so a descriptor alone
/// proves nothing about the lease. The lease is only still ours while the
/// derived path still names this object.
nonisolated struct SingleInstanceLeaseIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let generation: UInt32
    let birthTimeSeconds: Int64
    let birthTimeNanoseconds: Int64

    init(status: stat) {
        device = status.st_dev
        inode = status.st_ino
        generation = status.st_gen
        birthTimeSeconds = Int64(status.st_birthtimespec.tv_sec)
        birthTimeNanoseconds = Int64(status.st_birthtimespec.tv_nsec)
    }
}

/// The doorbell a second process rings so that the first one shows itself.
///
/// A second launch has nothing of its own to show: QotaFolio has no Dock icon and no window,
/// so a process that stands down leaves the user staring at the desktop. It cannot ask the
/// running instance directly either. The app is sandboxed without
/// `com.apple.security.automation.apple-events`, so an Apple Event is refused, and asking
/// LaunchServices to reopen "QotaFolio" cannot name WHICH instance when two copies answer to
/// the same bundle identifier.
///
/// What the two processes provably share is this file. It is the object whose exclusive lock
/// has just told the second process that a first one is here, both reach it through the same
/// container, and cleanup already owns its removal. One byte written to it is the whole
/// signal; the holder watches it and shows its panel.
nonisolated struct SingleInstanceLeaseDoorbell: Sendable {
    let leasePath: String

    /// Rings the running instance. Throws rather than failing quietly: a ring that does not
    /// arrive is a second launch that does nothing.
    func ring() throws {
        let descriptor = Darwin.open(leasePath, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw SingleInstanceLease.LeaseError.doorbellFailed(errno)
        }
        defer { _ = close(descriptor) }

        // Written at a fixed offset, so the file stays one byte long however many times the
        // app is launched again. The value carries nothing: the write event is the message.
        var beat: UInt8 = 1
        guard pwrite(descriptor, &beat, 1, 0) == 1 else {
            throw SingleInstanceLease.LeaseError.doorbellFailed(errno)
        }
    }
}

nonisolated final class SingleInstanceLease {
    enum AcquireResult {
        case acquired(SingleInstanceLease)
        /// Another process holds the lease. The value reaches it.
        case alreadyRunning(SingleInstanceLeaseDoorbell)
    }

    enum LeaseError: LocalizedError, Equatable, Sendable {
        case invalidLeaseLocation
        case applicationSupportUnavailable
        case unsafeDirectory
        case openFailed(Int32)
        case unsafeLockFile
        case lockFailed(Int32)
        case ownershipLost
        case leaseIdentityDestroyed
        case doorbellFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .invalidLeaseLocation:
                "The QotaFolio process lock is not where it should be."
            case .applicationSupportUnavailable:
                "The application support directory is unavailable."
            case .unsafeDirectory:
                "The QotaFolio application support directory is not safe to use."
            case .openFailed(let code):
                "The QotaFolio process lock could not be opened (errno \(code))."
            case .unsafeLockFile:
                "The QotaFolio process lock is not a safe regular file."
            case .lockFailed(let code):
                "The QotaFolio process lock could not be acquired (errno \(code))."
            case .ownershipLost:
                "The QotaFolio process no longer owns its single-instance lease."
            case .leaseIdentityDestroyed:
                "QotaFolio removal deleted the file that proves this process owns its lease."
            case .doorbellFailed(let code):
                "QotaFolio is already running and could not be asked to show itself (errno \(code))."
            }
        }
    }

    private let fileDescriptor: Int32
    private let leaseIdentity: SingleInstanceLeaseIdentity
    private let identity: AppIdentity
    private let locations: AppIdentityLocations
    private var doorbellSource: (any DispatchSourceFileSystemObject)?

    private init(
        fileDescriptor: Int32,
        leaseIdentity: SingleInstanceLeaseIdentity,
        identity: AppIdentity,
        locations: AppIdentityLocations
    ) {
        self.fileDescriptor = fileDescriptor
        self.leaseIdentity = leaseIdentity
        self.identity = identity
        self.locations = locations
    }

    deinit {
        doorbellSource?.cancel()
        _ = flock(fileDescriptor, LOCK_UN)
        _ = close(fileDescriptor)
    }

    /// Calls `handler` each time another process rings this lease.
    ///
    /// The watch descriptor is opened `O_EVTONLY`: it exists only to receive notifications, it
    /// keeps no volume busy, and it takes no lock, so it cannot disturb the exclusive lock this
    /// lease already holds on the same file. A delete or a rename means cleanup took the file
    /// away, and the watch ends with it rather than firing on a name that is no longer ours.
    func observeDoorbell(_ handler: @escaping @Sendable @MainActor () -> Void) {
        guard doorbellSource == nil else { return }
        let descriptor = Darwin.open(
            locations.singleInstanceLeasePath,
            O_EVTONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [source] in
            guard source.data.isDisjoint(with: [.delete, .rename, .revoke]) else {
                source.cancel()
                return
            }
            MainActor.assumeIsolated(handler)
        }
        source.setCancelHandler { _ = close(descriptor) }
        doorbellSource = source
        source.resume()
    }

    /// Proves this process still owns the lease its own identity names.
    ///
    /// Removing the user's data deletes the lease file, because the sandbox gives it nowhere to
    /// live except inside the container that goes. So this proof checks the derived path still
    /// names the exact object the lease was granted on, rather than trusting the descriptor: a
    /// held descriptor keeps working after its name is unlinked.
    func proveCurrentProcessOwnsLease() throws {
        let current = try Self.validateOwnedRegularFile(fileDescriptor)
        guard current == leaseIdentity else {
            throw LeaseError.leaseIdentityDestroyed
        }

        // The lease path is re-derived on every proof. No cached path string is ever trusted.
        let derived = AppIdentityLocations(
            identity: identity,
            dataDirectoryPath: locations.dataDirectoryPath
        )
        guard derived == locations else {
            throw LeaseError.invalidLeaseLocation
        }
        try Self.requireLeasePathStillNames(leaseIdentity, locations: derived)

        guard fcntl(fileDescriptor, F_GETFD) != -1,
              flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw LeaseError.ownershipLost
        }
    }

    static func acquire(fileManager: FileManager = .default) throws -> AcquireResult {
        let dataDirectory: URL
        do {
            dataDirectory = try OwnedContainerDataDirectory.resolve(fileManager: fileManager)
        } catch {
            throw LeaseError.applicationSupportUnavailable
        }
        return try acquire(
            identity: .current,
            dataDirectoryURL: dataDirectory,
            enforceContainerLocation: true,
            fileManager: fileManager
        )
    }

    static func acquire(
        identity: AppIdentity,
        dataDirectoryURL: URL,
        enforceContainerLocation: Bool,
        fileManager: FileManager = .default
    ) throws -> AcquireResult {
        let dataPath = dataDirectoryURL.standardizedFileURL.path
        if enforceContainerLocation {
            guard dataPath.hasSuffix("/" + identity.sandboxDataRelativePath) else {
                throw LeaseError.applicationSupportUnavailable
            }
        }
        let locations = AppIdentityLocations(
            identity: identity,
            dataDirectoryPath: dataPath
        )

        let directoryURL = URL(
            fileURLWithPath: locations.applicationSupportDirectoryPath,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try validateOwnedDirectory(directoryURL)

        let descriptor = Darwin.open(
            locations.singleInstanceLeasePath,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw LeaseError.openFailed(errno)
        }

        do {
            let leaseIdentity = try validateOwnedRegularFile(descriptor)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let lockError = errno
                if lockError == EWOULDBLOCK || lockError == EAGAIN {
                    _ = close(descriptor)
                    return .alreadyRunning(
                        SingleInstanceLeaseDoorbell(
                            leasePath: locations.singleInstanceLeasePath
                        )
                    )
                }
                throw LeaseError.lockFailed(lockError)
            }

            try requireLeasePathStillNames(leaseIdentity, locations: locations)
            return .acquired(
                SingleInstanceLease(
                    fileDescriptor: descriptor,
                    leaseIdentity: leaseIdentity,
                    identity: identity,
                    locations: locations
                )
            )
        } catch {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw error
        }
    }

    private static func requireLeasePathStillNames(
        _ identity: SingleInstanceLeaseIdentity,
        locations: AppIdentityLocations
    ) throws {
        var status = stat()
        guard lstat(locations.singleInstanceLeasePath, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              SingleInstanceLeaseIdentity(status: status) == identity else {
            throw LeaseError.leaseIdentityDestroyed
        }
    }

    private static func validateOwnedDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == geteuid() else {
            throw LeaseError.unsafeDirectory
        }
        guard chmod(url.path, S_IRWXU) == 0 else {
            throw LeaseError.unsafeDirectory
        }
    }

    private static func validateOwnedRegularFile(
        _ descriptor: Int32
    ) throws -> SingleInstanceLeaseIdentity {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid() else {
            throw LeaseError.unsafeLockFile
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw LeaseError.unsafeLockFile
        }
        return SingleInstanceLeaseIdentity(status: status)
    }
}
