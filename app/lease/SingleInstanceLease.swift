import Darwin
import Dispatch
import Foundation

/// One running copy of the app per identity: an exclusive lock on one file in the identity's support folder.
///
/// A second launch finds the lock taken and has nothing of its own to show: the app has no Dock icon and no
/// window. So it rings the first copy through the same file, with one byte written to it, and the holder
/// answers by showing its panel.
///
/// The lease cannot see version 1.0.0, whose lock is inside its sandbox container. The app makes that check
/// itself, where it starts.
nonisolated final class SingleInstanceLease {
    nonisolated enum Acquired {
        case held(SingleInstanceLease)
        /// Another process holds the lease. The doorbell reaches it.
        case taken(Doorbell)
    }

    nonisolated enum LeaseError: LocalizedError, Equatable, Sendable {
        case unsafeFolder
        case openFailed(Int32)
        case unsafeFile
        case lockFailed(Int32)
        case fileReplaced
        case ringFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .unsafeFolder:
                "The QotaFolio support folder is not safe to use."
            case .openFailed(let code):
                "The QotaFolio process lock could not be opened (errno \(code))."
            case .unsafeFile:
                "The QotaFolio process lock is not a safe regular file."
            case .lockFailed(let code):
                "The QotaFolio process lock could not be acquired (errno \(code))."
            case .fileReplaced:
                "The QotaFolio process lock was replaced while it was being taken."
            case .ringFailed(let code):
                "QotaFolio is already running and could not be asked to show itself (errno \(code))."
            }
        }
    }

    nonisolated struct Doorbell: Sendable {
        let file: URL

        /// Throws rather than failing quietly: a ring that does not arrive is a second launch that does nothing.
        func ring() throws {
            let descriptor = Darwin.open(file.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw LeaseError.ringFailed(errno) }
            defer { _ = close(descriptor) }
            // At a fixed offset, so the file stays one byte long however often the app is launched again.
            var beat: UInt8 = 1
            guard pwrite(descriptor, &beat, 1, 0) == 1 else { throw LeaseError.ringFailed(errno) }
        }
    }

    let file: URL
    private let descriptor: Int32
    private var doorbellWatch: (any DispatchSourceFileSystemObject)?

    private init(file: URL, descriptor: Int32) {
        self.file = file
        self.descriptor = descriptor
    }

    deinit {
        doorbellWatch?.cancel()
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    /// Takes the lease on `file`, making its folder owner-only, or finds it taken.
    static func acquire(at file: URL) throws -> Acquired {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try requireOwnedFolder(folder.path)

        let descriptor = Darwin.open(file.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw LeaseError.openFailed(errno) }
        do {
            let opened = try requireOwnedFile(descriptor)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let code = errno
                guard code == EWOULDBLOCK else { throw LeaseError.lockFailed(code) }
                _ = close(descriptor)
                return .taken(Doorbell(file: file))
            }
            // A held lock proves nothing if the name was unlinked between the open and the lock: another
            // process would create a new file under it and lock that one too.
            guard FileObject(path: file.path) == opened else { throw LeaseError.fileReplaced }
            return .held(SingleInstanceLease(file: file, descriptor: descriptor))
        } catch {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw error
        }
    }

    /// Calls `handler` on the main actor each time another process rings this lease.
    ///
    /// The watch opens the file `O_EVTONLY`: it takes no lock, so it cannot disturb the one this lease holds.
    /// A delete or a rename means the file was taken away, and the watch ends with it.
    func observeDoorbell(_ handler: @escaping @Sendable @MainActor () -> Void) {
        guard doorbellWatch == nil else { return }
        let watched = Darwin.open(file.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard watched >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watched,
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
        source.setCancelHandler { _ = close(watched) }
        doorbellWatch = source
        source.resume()
    }

    private static func requireOwnedFolder(_ path: String) throws {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              chmod(path, S_IRWXU) == 0 else {
            throw LeaseError.unsafeFolder
        }
    }

    private static func requireOwnedFile(_ descriptor: Int32) throws -> FileObject {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw LeaseError.unsafeFile
        }
        return FileObject(status)
    }
}

/// The exact file object behind a name: its device, its inode and its birth time.
private nonisolated struct FileObject: Equatable {
    let device: Int32
    let inode: UInt64
    let birth: timespec

    init(_ status: stat) {
        device = status.st_dev
        inode = status.st_ino
        birth = status.st_birthtimespec
    }

    init?(path: String) {
        var status = stat()
        guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        self.init(status)
    }

    static func == (a: Self, b: Self) -> Bool {
        a.device == b.device && a.inode == b.inode
            && a.birth.tv_sec == b.birth.tv_sec && a.birth.tv_nsec == b.birth.tv_nsec
    }
}
