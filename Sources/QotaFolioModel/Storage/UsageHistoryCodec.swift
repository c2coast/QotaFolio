import Foundation

/// Which of the two history files a read or a write is about.
///
/// There are two rather than one because they are read at different moments and one of those
/// moments is the launch path. The snapshot book is a couple of kilobytes and is read before
/// the first fetch, so the panel is full the instant it opens. The trace book is up to two
/// orders of magnitude larger and nothing on the launch path wants it: it is read on the
/// history subsystem's own queue, minutes later, when the first batch of samples is written.
public nonisolated enum UsageHistoryFile: String, Sendable, CaseIterable {
    /// The last successful poll per account.
    case snapshots
    /// The sample rings and the completed-window ledger.
    case traces

    /// Alongside `catalog.json` in the App Group container, so a removal takes it without
    /// naming it and the widget reads it without asking the app.
    public var leafName: String {
        switch self {
        case .snapshots: "usage-snapshots.json"
        case .traces: "usage-history.json"
        }
    }

    public var maximumBytes: Int {
        switch self {
        case .snapshots: UsageHistoryPolicy.maximumSnapshotBytes
        case .traces: UsageHistoryPolicy.maximumHistoryBytes
        }
    }
}

/// Why history is not available.
///
/// **Every case here means the same thing to the app: use nothing, poll normally, write over
/// it at the next flush.** There is deliberately no `corrupt`. The catalog has one because a
/// broken account list has to be quarantined and confessed to the user; history has neither
/// a user-visible consequence nor anything worth quarantining. Nothing in this type gates
/// the app, nothing in it reaches a surface, and no branch anywhere reads it to decide
/// behaviour — it exists so a log line and a test can say which path was taken.
public nonisolated enum UsageHistoryUnavailableReason: Equatable, Sendable {
    /// Proven absent. This is the ordinary state on a first launch, and on the first launch
    /// after an update for everyone who already has the app.
    case absent
    /// The read did not happen — descriptors, memory, a directory this build may not use.
    /// Nothing was learned about the bytes, so nothing is claimed about them, and the
    /// subsystem writes nothing this round rather than overwriting a file it could not read.
    case obstructed
    /// The bytes were read and they are not a history document this build understands.
    case unrecognisedBytes
    /// A later version of QotaFolio wrote this. Its samples are not read, and the next flush
    /// replaces them with this version's. A downgrade losing a convenience file is a fair
    /// price for a downgrade that keeps working.
    case newerSchema(UInt16)
}

public nonisolated enum UsageHistoryBytes: Sendable {
    case loaded(Data)
    case unavailable(UsageHistoryUnavailableReason)
}

public nonisolated enum UsageHistoryRead<Book: Sendable>: Sendable {
    case loaded(Book)
    case unavailable(UsageHistoryUnavailableReason)

    public var book: Book? {
        guard case .loaded(let book) = self else { return nil }
        return book
    }

    public var unavailableReason: UsageHistoryUnavailableReason? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

/// The two files' shared shape: a schema version, and rows that must satisfy their own
/// invariants before this build will read them.
public nonisolated protocol UsageHistoryBookProtocol: Codable, Equatable, Sendable {
    var schemaVersion: UInt16 { get }
    /// Checked once, at the door, so no reader downstream has to. A window whose two sample
    /// arrays disagree in length, or whose timestamps do not strictly increase, is refused
    /// here rather than producing a projection nobody can explain.
    var isStructurallySound: Bool { get }
}

public nonisolated enum UsageHistoryCodec {
    public static let schemaVersion: UInt16 = 1

    /// The bytes to write, or `nil` when there are none this build would agree to read back.
    ///
    /// The size bound is applied here for the same reason `FileCatalogStore` applies it: the
    /// writer must never author bytes the reader refuses. With the caps in
    /// `UsageHistoryPolicy` the bound is arithmetic and cannot be reached, so `nil` means a
    /// bug — and the response to a bug in a convenience file is to skip the write, not to
    /// shed data until it fits.
    public static func encode(
        _ book: some UsageHistoryBookProtocol,
        for file: UsageHistoryFile
    ) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(book), data.count <= file.maximumBytes else {
            return nil
        }
        return data
    }

    /// Every verdict reachable here is a statement about bytes that were read in full. It
    /// never answers `.absent` and never answers `.obstructed`: absence is proven by
    /// inspecting the directory, and an obstruction is a fact about the machine that a
    /// decoder cannot observe.
    public static func decode<Book: UsageHistoryBookProtocol>(
        _ data: Data,
        as _: Book.Type = Book.self
    ) -> UsageHistoryRead<Book> {
        guard let book = try? JSONDecoder().decode(Book.self, from: data) else {
            return .unavailable(.unrecognisedBytes)
        }
        guard book.schemaVersion <= schemaVersion else {
            return .unavailable(.newerSchema(book.schemaVersion))
        }
        guard book.schemaVersion == schemaVersion, book.isStructurallySound else {
            return .unavailable(.unrecognisedBytes)
        }
        return .loaded(book)
    }

    public static func read<Book: UsageHistoryBookProtocol>(
        _ bytes: UsageHistoryBytes,
        as type: Book.Type = Book.self
    ) -> UsageHistoryRead<Book> {
        switch bytes {
        case .loaded(let data): decode(data, as: type)
        case .unavailable(let reason): .unavailable(reason)
        }
    }
}

