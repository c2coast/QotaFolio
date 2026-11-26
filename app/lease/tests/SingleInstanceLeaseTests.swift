import Darwin
import Foundation
import Testing

/// The lease on a temporary folder, with a real lock. `flock` locks belong to an open file, not to a process,
/// so a second acquire in the same test meets the first exactly as a second launch would.
struct SingleInstanceLeaseTests {
    let home: URL
    let file: URL

    init() {
        home = FileManager.default.temporaryDirectory.appending(path: "lease-\(UUID().uuidString)")
        file = home.appending(path: "Library/Application Support/net.example.app/single-instance.lock")
    }

    @Test("The first launch holds the lease, in a folder only its owner can open")
    func theFirstLaunchHoldsTheLeaseInAnOwnerOnlyFolder() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let acquired = try SingleInstanceLease.acquire(at: file)
        guard case .held(let lease) = acquired else {
            Issue.record("The first launch found the lease taken.")
            return
        }
        #expect(lease.file == file)
        var status = stat()
        #expect(lstat(file.deletingLastPathComponent().path, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o700)
    }

    @Test("A second launch finds the lease taken, until the first lets go")
    func aSecondLaunchFindsTheLeaseTakenUntilTheFirstLetsGo() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        do {
            let first = try #require(try heldLease())
            try withExtendedLifetime(first) {
                guard case .taken = try SingleInstanceLease.acquire(at: file) else {
                    Issue.record("A second launch took a lease the first still holds.")
                    return
                }
            }
        }
        guard case .held = try SingleInstanceLease.acquire(at: file) else {
            Issue.record("The lease stayed taken after its holder let go.")
            return
        }
    }

    @Test("A second launch rings the first, and the first hears it", .timeLimit(.minutes(1)))
    @MainActor
    func aSecondLaunchRingsTheFirst() async throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try #require(try heldLease())
        let (rings, ringing) = AsyncStream<Void>.makeStream()
        first.observeDoorbell { ringing.yield() }

        guard case .taken(let doorbell) = try SingleInstanceLease.acquire(at: file) else {
            Issue.record("A second launch took a lease the first still holds.")
            return
        }
        try doorbell.ring()
        var heard = rings.makeAsyncIterator()
        #expect(await heard.next() != nil)
        withExtendedLifetime(first) {}
    }

    @Test("A lock file that is a link is refused, so the lease never writes through it")
    func aLockFileThatIsALinkIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let elsewhere = home.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)

        #expect(throws: SingleInstanceLease.LeaseError.openFailed(ELOOP)) {
            try SingleInstanceLease.acquire(at: file)
        }
    }

    @Test("A support folder that is a link is refused")
    func aSupportFolderThatIsALinkIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: home) }
        let elsewhere = home.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent().deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: file.deletingLastPathComponent(), withDestinationURL: elsewhere)

        #expect(throws: SingleInstanceLease.LeaseError.unsafeFolder) {
            try SingleInstanceLease.acquire(at: file)
        }
    }

    private func heldLease() throws -> SingleInstanceLease? {
        guard case .held(let lease) = try SingleInstanceLease.acquire(at: file) else { return nil }
        return lease
    }
}
