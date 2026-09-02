import Dispatch
import QotaFolioCore

/// The three outcomes a catalog commit can have, stated once instead of being
/// rebuilt from an error at every consumer.
///
/// - `committed`: the replacement is on the device. Both `F_FULLFSYNC` calls
///   returned success and the leaf was re-verified as the inode that was written.
/// - `notReplaced`: nothing was replaced. The previous catalog is provably intact,
///   so the in-memory optimistic mutation must be rolled back.
/// - `replacementDurabilityUncertain`: the rename happened but durability was not
///   confirmed. Neither "old" nor "new" can be claimed, so the catalog is quarantined
///   rather than rolled back.
public nonisolated enum CatalogCommitOutcome: Sendable {
    case committed
    case notReplaced(CatalogPersistenceError)
    case replacementDurabilityUncertain(CatalogPersistenceError)
}

/// The isolation domain that owns catalog file I/O.
///
/// `CatalogFileIO.writeCatalog` issues `F_FULLFSYNC` twice per commit — once on the
/// staging file and once on the parent directory after the rename — and neither call
/// returns until the storage device acknowledges a full cache flush. That is a blocking
/// device wait, and it must run neither on the MainActor nor on the cooperative thread
/// pool, which has roughly one thread per core and is shared with every provider request,
/// the polling engine, and the vault.
///
/// So this actor runs on its own `DispatchSerialQueue` rather than the default actor
/// executor. A commit blocks one dedicated thread that exists for exactly this purpose.
///
/// The queue is serial, but serial does NOT mean the writer decides commit order: Swift
/// makes no promise about the order in which concurrent calls to an actor are serviced,
/// whatever executor the actor runs on. Ordering is established by the caller —
/// `AccountCatalog` chains its commits on the MainActor so that only one commit is ever
/// in flight and a later commit cannot start before an earlier one's outcome is applied.
public actor CatalogCommitWriter {
    private let queue: DispatchSerialQueue
    private let store: any AccountCatalogPersisting

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init(store: any AccountCatalogPersisting) {
        self.store = store
        queue = DispatchSerialQueue(
            label: "net.c2coast.QotaFolio.catalog-commit",
            qos: .userInitiated
        )
    }

    /// Performs one durable commit and answers with the outcome.
    ///
    /// `AccountCatalogPersisting.save` is deliberately still a synchronous `nonisolated`
    /// function. A synchronous `nonisolated` call inherits its caller's executor, so
    /// calling it from here runs the whole hardened write — staging file, device flush,
    /// atomic rename, parent-directory flush, re-verification — on this actor's private
    /// serial queue.
    func commit(_ records: [AccountRecord]) -> CatalogCommitOutcome {
        do {
            try store.save(records)
            return .committed
        } catch {
            switch error {
            case .encoding:
                return .notReplaced(error)
            case .write(let underlying):
                let disposition = (underlying as? CatalogWriteFailure)?.disposition
                    ?? .notReplaced
                switch disposition {
                case .notReplaced:
                    return .notReplaced(error)
                case .replacementDurabilityUncertain:
                    return .replacementDurabilityUncertain(error)
                }
            }
        }
    }
}
