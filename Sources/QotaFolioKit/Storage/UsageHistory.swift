import Dispatch
import Foundation
import Kit
import QotaFolioCore

/// Each account's readings, as Kit reads them: the trace and the snapshots, in time order, the
/// newest poll last. Keyed by the app's account.
public typealias AccountReadings = [QotaFolioModel.AccountID: [Reading]]

/// One thing that happened, waiting to be written.
public nonisolated enum UsageHistoryMutation: Sendable {
    case observed(account: QotaFolioModel.AccountID, snapshot: UsageSnapshot)
    case forgotten(QotaFolioModel.AccountID)
}

/// The isolation domain that owns history file I/O.
///
/// Modelled on `CatalogCommitWriter`, and different from it in one deliberate way: **this
/// writer never asks the device for a flush.**
///
/// `CatalogFileIO.writeCatalog` issues `F_FULLFSYNC` twice per commit, and it is right to.
/// The catalog is the account list, and losing an account row to a power failure costs the
/// user a browser sign-in. History costs nothing: a lost sample is one dot in a trace of
/// hundreds, and a lost snapshot is a panel that fills three minutes later instead of at
/// once. A device flush is a blocking wait on the storage controller, and one every minute
/// for years is precisely the kind of expense that makes a menu-bar app feel bad and never
/// appears in a test. So the commit here is: write to a staging file, rename it over the
/// target. The rename is atomic, so a reader never sees a half-written book, and the page
/// cache carries the bytes to the device on the system's own schedule, batched with
/// everything else the machine is doing. A crash, a force-quit, a log-out and a restart all
/// keep the data; only losing power loses it, and only the last few minutes of it.
///
/// The serial queue stays, because `write(2)` can still block a thread — briefly, on
/// allocation — and the cooperative pool has about one thread per core and is shared with
/// every provider request. The queue runs at `.utility`: nothing in the app ever waits on
/// this work, which is the whole point of the API above it.
public actor UsageHistoryWriter {
    private let queue: DispatchSerialQueue
    private let files: any SharedFileAccess
    private let snapshotWriteDeadline: Duration
    private let traceWriteDeadline: Duration
    private var snapshots: UsageSnapshotBook?
    private var traces: UsageTraceBook?

    /// Set when a book in memory has moved ahead of its file, cleared when the file catches
    /// up. Derived from an `Equatable` comparison at the moment of the change, so it is never
    /// a second opinion about whether there is anything to write.
    private var snapshotsAreUnwritten = false
    private var snapshotsWrittenAt: Date?
    private var tracesAreUnwritten = false
    private var tracesWrittenAt: Date?

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init(
        files: any SharedFileAccess,
        snapshotWriteDeadline: Duration = UsageHistoryPolicy.writeDeadline,
        traceWriteDeadline: Duration = UsageHistoryPolicy.traceWriteDeadline
    ) {
        self.files = files
        self.snapshotWriteDeadline = snapshotWriteDeadline
        self.traceWriteDeadline = traceWriteDeadline
        queue = DispatchSerialQueue(
            label: "net.c2coast.QotaFolio.usage-history",
            qos: .utility
        )
    }

    /// Applies a batch to the books in memory, then reads each account's readings from them.
    ///
    /// **The books move at once; the files move on their own clocks.** That separation is the
    /// whole shape of this actor. The readings are read from the books the instant a sample
    /// arrives, and the device sees it when its book's deadline says so.
    ///
    /// The readings are read through the reader `qota` and `tools/forecast` use on the files,
    /// from the books encoded as the files are, so the three read the same readings. The trace
    /// file keeps a week's sample a quarter-hour apart at most, and the snapshot book holds the
    /// newest poll, so the readings end with the poll that just arrived.
    ///
    /// The books are read from the device on the first batch and held afterwards, so the
    /// steady state is no read at all — and no write either for a book the batch left exactly
    /// as it found it. Both book types are `Equatable`, so "did this change anything" is a
    /// question the data answers rather than one the caller has to promise. An empty batch
    /// reads the books and changes nothing.
    ///
    /// `nil` says the books could not be read, so nothing was applied and there is nothing
    /// honest to say about any account.
    @discardableResult
    func apply(_ mutations: [UsageHistoryMutation], at now: Date) -> AccountReadings? {
        // An obstructed read is the one case that must not be treated as an empty book.
        // Nothing was learned about the file, so overwriting it would trade eight days of
        // history for a momentary descriptor shortage. The batch is dropped instead — a few
        // minutes of samples — and the next flush reads again.
        guard var snapshotBook = book(&snapshots, .snapshots, { UsageSnapshotBook() }),
              var traceBook = book(&traces, .traces, { UsageTraceBook() }) else { return nil }

        for mutation in mutations {
            switch mutation {
            case .observed(let account, let snapshot):
                snapshotBook.record(PersistedUsageSnapshot(account: account, snapshot: snapshot))
                traceBook.observe(snapshot, for: account)
            case .forgotten(let account):
                snapshotBook.forget(account)
                traceBook.forget(account)
            }
        }

        if snapshotBook != snapshots { snapshotsAreUnwritten = true }
        if traceBook != traces { tracesAreUnwritten = true }
        snapshots = snapshotBook
        traces = traceBook

        // The snapshot book goes down NOW, not at the deadline. `qota status` reads these bytes
        // with the trace, and a person who runs it after the panel moved expects the panel's
        // reading. It is a few kilobytes and the write is an atomic rename into the page cache;
        // the deadline exists for the trace book, which is forty times larger and keeps its own
        // clock.
        if snapshotsAreUnwritten { writeSnapshots(at: now) }
        return AccountReadings(traces: traceBook, snapshots: snapshotBook)
    }

    /// Writes whichever files are past their own deadline. Answers whether anything is still
    /// waiting, so the caller knows to come back.
    @discardableResult
    func writeDueFiles(at now: Date) -> Bool {
        if isDue(snapshotsAreUnwritten, snapshotsWrittenAt, snapshotWriteDeadline, now) {
            writeSnapshots(at: now)
        }
        if isDue(tracesAreUnwritten, tracesWrittenAt, traceWriteDeadline, now) {
            writeTraces(at: now)
        }
        return snapshotsAreUnwritten || tracesAreUnwritten
    }

    /// Puts everything outstanding on the device now, whatever the deadlines say.
    ///
    /// The one call that ignores them, and it exists for the one moment that cannot wait: a
    /// graceful quit, which is also the only exit the app can act on. Called with nothing
    /// outstanding it does nothing at all.
    func writeEverything(at now: Date) {
        if snapshotsAreUnwritten { writeSnapshots(at: now) }
        if tracesAreUnwritten { writeTraces(at: now) }
    }

    private func isDue(
        _ unwritten: Bool,
        _ writtenAt: Date?,
        _ deadline: Duration,
        _ now: Date
    ) -> Bool {
        guard unwritten else { return false }
        // Nothing written yet in this process: the first samples after launch go down on the
        // first drain, so a crash minutes after start still leaves a file behind.
        guard let writtenAt else { return true }
        // A clock that moved backwards would otherwise park the file for as long as the
        // correction was large, so a negative elapsed time is due immediately.
        let elapsed = now.timeIntervalSince(writtenAt)
        return elapsed < 0 || Duration.seconds(elapsed) >= deadline
    }

    private func writeSnapshots(at now: Date) {
        guard let snapshots,
              let data = UsageHistoryCodec.encode(snapshots, for: .snapshots) else { return }
        files.write(data, to: .snapshots)
        snapshotsAreUnwritten = false
        snapshotsWrittenAt = now
    }

    private func writeTraces(at now: Date) {
        guard let traces, let data = UsageHistoryCodec.encode(traces, for: .traces) else { return }
        files.write(data, to: .traces)
        tracesAreUnwritten = false
        tracesWrittenAt = now
    }

    private func book<Book: UsageHistoryBookProtocol>(
        _ held: inout Book?,
        _ file: SharedFile,
        _ empty: () -> Book
    ) -> Book? {
        if let held { return held }
        let read: UsageHistoryRead<Book> = UsageHistoryCodec.read(files.read(file))
        switch read {
        case .loaded(let book):
            held = book
            return book
        case .unavailable(.obstructed):
            return nil
        case .unavailable:
            let book = empty()
            held = book
            return book
        }
    }
}

/// What QotaFolio remembers between launches: the last reading for every account, and enough
/// of the shape of the last few days for the Engine to say where the week is going.
///
/// ## The two calls
///
/// ```swift
/// // At start, before the first fetch. The panel draws from this instead of nothing.
/// let restored = history.restoreSnapshots()
///
/// // After every successful poll. Returns instantly; the write happens later, elsewhere.
/// history.record(snapshot, for: account.id)
/// ```
///
/// Each account's readings are read from the books the instant they change, and arrive at
/// `onReadings`.
///
/// `record` is not `async` and returns nothing, on purpose. There is no `await` to write and
/// no outcome to branch on, so no call site can be made to wait on a history write, and none
/// can be made to care whether one succeeded. That is the correct relationship: quota
/// numbers are the product and history is a convenience that must never stand in front of
/// them.
///
/// `forget(_:)` is a third call and an optional one. Wire it to Remove and an account's
/// history goes when the account does; leave it unwired and the history ages out by itself
/// within eight days, because `UsageHistoryPolicy.accountHorizon` drops an account nobody
/// has polled. Wiring it is better.
///
/// ## Failure
///
/// Nothing here throws and nothing here reports. An absent file, an unreadable file, a file
/// from a newer QotaFolio and a file the machine would not open all produce the same
/// behaviour: `restoreSnapshots()` answers with nothing, the app polls exactly as it would
/// have, and the next flush writes a good file over a bad one. A first launch and a broken
/// file are the same day for the user, and on both of them the app works.
@MainActor
public final class UsageHistory {
    private let files: any SharedFileAccess
    private let writer: UsageHistoryWriter
    private let clock: @Sendable () -> Date
    private let writeDeadline: Duration

    /// Where each account's readings go. `AccountsStore` sets this and publishes what arrives.
    ///
    /// A property rather than an initialiser argument because the store owns the history and
    /// the history hands the store back an answer: two objects that are made in one order and
    /// wired in the other.
    public var onReadings: (@MainActor (AccountReadings) -> Void)?

    private var deadline: Task<Void, Never>?

    /// Writes are chained here rather than left to actor ordering.
    ///
    /// Swift promises nothing about the order two calls to an actor are serviced in, and
    /// applying a later batch before an earlier one would push a ring's timestamps backwards
    /// and make it discard samples it should have kept. `AccountCatalog` chains its commits
    /// on the main actor for the same reason; this is that idiom.
    private var chain: Task<Void, Never> = Task {}

    public init(
        files: any SharedFileAccess,
        clock: @escaping @Sendable () -> Date = { Date() },
        writeDeadline: Duration = UsageHistoryPolicy.writeDeadline,
        traceWriteDeadline: Duration = UsageHistoryPolicy.traceWriteDeadline
    ) {
        self.files = files
        self.clock = clock
        self.writeDeadline = writeDeadline
        writer = UsageHistoryWriter(
            files: files,
            snapshotWriteDeadline: writeDeadline,
            traceWriteDeadline: traceWriteDeadline
        )
    }

    /// The last successful poll for every account that has one. Call once, at start, before
    /// the first fetch.
    ///
    /// Synchronous, and on this actor, because that is what makes the panel full at the
    /// instant it opens rather than one turn of the run loop later. The cost it spends there
    /// is a few directory opens and one read of a file measured in single-digit kilobytes.
    /// Measured on the largest book this product can author — five accounts, four windows
    /// each, 4 052 bytes — it is **0.18 ms on average and 0.31 ms at worst**, which is an
    /// order of magnitude less than the Keychain query the same launch already makes.
    ///
    /// Each snapshot carries the `fetchedAt` it was true at, so the panel ages it. A reading
    /// from four hours ago is worth showing; it is worth showing as four hours old.
    public func restoreSnapshots() -> [QotaFolioModel.AccountID: UsageSnapshot] {
        let read: UsageHistoryRead<UsageSnapshotBook> = UsageHistoryCodec.read(files.read(.snapshots))
        guard let book = read.book else { return [:] }
        return Dictionary(
            book.accounts.map { ($0.account, $0.makeUsageSnapshot()) },
            uniquingKeysWith: { _, later in later }
        )
    }

    /// Records one successful poll. Call it wherever the store applies a fresh snapshot.
    ///
    /// Returns immediately: this posts one value onto the writer's chain and, if no write is
    /// already scheduled, arms a single timer. Everything else — ring maintenance, the
    /// readings, encoding, the write — happens later and elsewhere.
    public func record(_ snapshot: UsageSnapshot, for account: QotaFolioModel.AccountID) {
        post([.observed(account: account, snapshot: snapshot)])
    }

    /// Drops one account's history. Call it where an account is removed.
    public func forget(_ account: QotaFolioModel.AccountID) {
        post([.forgotten(account)])
    }

    /// Reads the books and publishes each account's readings, with no sample. Call once, at
    /// start, so the panel has the week before the first poll lands.
    public func restoreReadings() {
        post([])
    }

    /// Writes anything buffered, now, and returns when it has been written.
    ///
    /// The one call here that can be awaited, and it has one purpose: a graceful quit, so the
    /// last few minutes of samples are kept rather than dropped. It is never needed on a hot
    /// path — the deadline covers those — and calling it on one would put a file write in
    /// front of the user.
    public func flush() async {
        deadline?.cancel()
        deadline = nil
        let previous = chain
        let writer = writer
        let now = clock()
        // Chained rather than awaited beside the posts, so the forced write sees every batch
        // already on the chain instead of racing them.
        chain = Task {
            await previous.value
            await writer.writeEverything(at: now)
        }
        await chain.value
    }

    // MARK: - Scheduling

    /// Posts a change to the writer at once, and arms the file deadline behind it.
    private func post(_ mutations: [UsageHistoryMutation]) {
        let previous = chain
        let writer = writer
        let now = clock()
        chain = Task { [weak self] in
            await previous.value
            guard let readings = await writer.apply(mutations, at: now) else { return }
            self?.onReadings?(readings)
        }
        armDeadline()
    }

    /// A deadline, not a debounce.
    ///
    /// The clock starts at the first unwritten change and later ones do not restart it, so
    /// staleness on disk is bounded at `writeDeadline` however busy the app is. It is armed on
    /// the transition from nothing-to-write to something-to-write and disarmed when it fires,
    /// so an idle QotaFolio holds no timer at all — and it is re-armed only while the writer
    /// says something is still waiting.
    private func armDeadline() {
        guard deadline == nil else { return }
        let interval = writeDeadline
        deadline = Task { [weak self] in
            try? await Task.sleep(
                for: interval,
                tolerance: UsageHistoryPolicy.writeDeadlineTolerance(for: interval)
            )
            guard !Task.isCancelled else { return }
            self?.deadlineFired()
        }
    }

    private func deadlineFired() {
        // Cleared first, so the write does not cancel the task it is running inside.
        deadline = nil
        let previous = chain
        let writer = writer
        let now = clock()
        chain = Task { [weak self] in
            await previous.value
            let outstanding = await writer.writeDueFiles(at: now)
            if outstanding { self?.armDeadline() }
        }
    }
}

extension AccountReadings {
    /// Each account's readings from the books, encoded as the files are and read by the reader
    /// the files are read by. A book this build cannot read says nothing of any account.
    public nonisolated init(traces: UsageTraceBook, snapshots: UsageSnapshotBook) {
        let history = UsageHistoryCodec.encode(traces, for: .traces)
        let newest = UsageHistoryCodec.encode(snapshots, for: .snapshots)
        let accounts = (try? LegacyHistory.readings(history: history, snapshots: newest)) ?? []
        self = Dictionary(accounts.compactMap { readings in
            UUID(uuidString: readings[0].account.rawValue).map { (QotaFolioModel.AccountID(rawValue: $0), readings) }
        }, uniquingKeysWith: { _, later in later })
    }
}
