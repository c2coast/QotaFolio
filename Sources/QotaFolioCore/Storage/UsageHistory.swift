import Dispatch
import Foundation

/// One thing that happened, waiting to be written.
public nonisolated enum UsageHistoryMutation: Sendable {
    case observed(account: AccountID, snapshot: UsageSnapshot, at: Date)
    case forgotten(AccountID)
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
    private let assessor: any FleetAssessing
    private let sentences: @Sendable (FleetAssessment) -> RecommendationSentences
    private let snapshotWriteDeadline: Duration
    private let traceWriteDeadline: Duration
    private var snapshots: UsageSnapshotBook?
    private var traces: UsageTraceBook?
    private var assessment: FleetAssessment?

    /// Set when a book in memory has moved ahead of its file, cleared when the file catches
    /// up. Derived from an `Equatable` comparison at the moment of the change, so it is never
    /// a second opinion about whether there is anything to write.
    private var snapshotsAreUnwritten = false
    private var snapshotsWrittenAt: Date?
    private var tracesAreUnwritten = false
    private var tracesWrittenAt: Date?
    private var recommendationIsUnwritten = false

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init(
        files: any SharedFileAccess,
        assessor: any FleetAssessing = SilentFleetAssessor(),
        sentences: @escaping @Sendable (FleetAssessment) -> RecommendationSentences = { _ in .none },
        snapshotWriteDeadline: Duration = UsageHistoryPolicy.writeDeadline,
        traceWriteDeadline: Duration = UsageHistoryPolicy.traceWriteDeadline
    ) {
        self.files = files
        self.assessor = assessor
        self.sentences = sentences
        self.snapshotWriteDeadline = snapshotWriteDeadline
        self.traceWriteDeadline = traceWriteDeadline
        queue = DispatchSerialQueue(
            label: "net.c2coast.QotaFolio.usage-history",
            qos: .utility
        )
    }

    /// Applies a batch to the books in memory, then asks the brain what the fleet looks like.
    ///
    /// **The books move at once; the files move on their own clocks.** That separation is the
    /// whole shape of this actor. Every reader — the brain here, the panel through
    /// `traceBook()`, the strip through the assessment this returns — sees the sample the
    /// instant it arrives, and the device sees it when its book's deadline says so. Batching
    /// the *books* would have meant the strip drawing a five-minute-old fleet; batching the
    /// *writes* costs nothing anyone can observe.
    ///
    /// The books are read from the device on the first batch and held afterwards, so the
    /// steady state is no read at all — and no write either for a book the batch left exactly
    /// as it found it. Both book types are `Equatable`, so "did this change anything" is a
    /// question the data answers rather than one the caller has to promise.
    ///
    /// The two books are written on different clocks, and the reason is in
    /// `UsageHistoryPolicy.traceWriteDeadline`: the snapshot book is small and is read at
    /// launch, the trace book is large and is read through `flush()`.
    ///
    /// `nil` says the books could not be read, so nothing was applied and there is nothing
    /// honest to say about the fleet.
    @discardableResult
    func apply(
        _ mutations: [UsageHistoryMutation],
        fleet: [FleetAccount],
        at now: Date
    ) -> FleetAssessment? {
        // An obstructed read is the one case that must not be treated as an empty book.
        // Nothing was learned about the file, so overwriting it would trade eight days of
        // history for a momentary descriptor shortage. The batch is dropped instead — a few
        // minutes of samples — and the next flush reads again.
        guard var snapshotBook = book(&snapshots, .snapshots, { UsageSnapshotBook() }),
              var traceBook = book(&traces, .traces, { UsageTraceBook() }) else { return nil }

        for mutation in mutations {
            switch mutation {
            case .observed(let account, let snapshot, let at):
                snapshotBook.record(PersistedUsageSnapshot(account: account, snapshot: snapshot))
                traceBook.observe(snapshot, for: account, at: usageHistoryEpochSeconds(at))
            case .forgotten(let account):
                snapshotBook.forget(account)
                traceBook.forget(account)
            }
        }

        if snapshotBook != snapshots { snapshotsAreUnwritten = true }
        if traceBook != traces { tracesAreUnwritten = true }
        snapshots = snapshotBook
        traces = traceBook

        return assess(fleet: fleet, at: now)
    }

    /// The brain, over the books as they stand. No sample, no file read, no write.
    ///
    /// Called on every poll from `apply`, and on its own when the assessment's own
    /// `nextReviewAt` comes round — a window that resets, or a verdict that changes, without
    /// anybody polling anything.
    @discardableResult
    func assess(fleet: [FleetAccount], at now: Date) -> FleetAssessment? {
        guard let traceBook = book(&traces, .traces, { UsageTraceBook() }),
              let snapshotBook = book(&snapshots, .snapshots, { UsageSnapshotBook() })
        else { return nil }
        let next = assessor.assess(
            FleetAssessmentRequest(
                traces: traceBook,
                snapshots: snapshotBook,
                fleet: fleet,
                now: now
            )
        )
        if next != assessment {
            assessment = next
            recommendationIsUnwritten = true
        }
        // The two small files go down NOW, not at the deadline. The Control and the widget are
        // reloaded the moment the store publishes this assessment, and what they read is these
        // bytes — a reload that outran the write would show the previous reading. They are a
        // few kilobytes and the write is an atomic rename into the page cache; the deadline
        // exists for the trace book, which is forty times larger and keeps its own clock.
        publishSmallFiles(at: now)
        return next
    }

    /// The snapshot book and the recommendation, written at once when they have changed.
    private func publishSmallFiles(at now: Date) {
        if snapshotsAreUnwritten { writeSnapshots(at: now) }
        if recommendationIsUnwritten { writeRecommendation() }
    }

    /// Writes whichever files are past their own deadline. Answers whether anything is still
    /// waiting, so the caller knows to come back.
    @discardableResult
    func writeDueFiles(at now: Date) -> Bool {
        if isDue(snapshotsAreUnwritten, snapshotsWrittenAt, snapshotWriteDeadline, now) {
            writeSnapshots(at: now)
        }
        // On the snapshot book's clock whether or not the book itself moved. A verdict
        // changes when a window resets and nobody polled, and an account that needs signing
        // in again never polls at all — in both cases `recommendation.json` is the only place
        // `qota which` can learn what the app thinks, so it must not wait for a sample that
        // is not coming.
        if isDue(recommendationIsUnwritten, snapshotsWrittenAt, snapshotWriteDeadline, now) {
            writeRecommendation()
        }
        if isDue(tracesAreUnwritten, tracesWrittenAt, traceWriteDeadline, now) {
            writeTraces(at: now)
        }
        return snapshotsAreUnwritten || tracesAreUnwritten || recommendationIsUnwritten
    }

    /// Puts everything outstanding on the device now, whatever the deadlines say.
    ///
    /// The one call that ignores them, and it exists for the one moment that cannot wait: a
    /// graceful quit, which is also the only exit the app can act on. Called with nothing
    /// outstanding it does nothing at all.
    func writeEverything(at now: Date) {
        if snapshotsAreUnwritten { writeSnapshots(at: now) }
        if tracesAreUnwritten { writeTraces(at: now) }
        if recommendationIsUnwritten { writeRecommendation() }
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

    /// The snapshot book, and the recommendation with it.
    ///
    /// One clock for both, because they say the same thing about the same moment: the last
    /// numbers this app saw, and what it decided from them. A `qota which` that answered from
    /// a recommendation five minutes ahead of the snapshots beside it would be reading two
    /// different instants and calling them one.
    private func writeSnapshots(at now: Date) {
        guard let snapshots,
              let data = UsageHistoryCodec.encode(snapshots, for: .snapshots) else { return }
        files.write(data, to: .snapshots)
        snapshotsAreUnwritten = false
        snapshotsWrittenAt = now
        if recommendationIsUnwritten { writeRecommendation() }
    }

    private func writeRecommendation() {
        guard let assessment else { return }
        let document = RecommendationDocument(
            assessment: assessment,
            sentences: sentences(assessment)
        )
        guard let data = RecommendationCodec.encode(document) else { return }
        files.write(data, to: .recommendation)
        recommendationIsUnwritten = false
    }

    private func writeTraces(at now: Date) {
        guard let traces, let data = UsageHistoryCodec.encode(traces, for: .traces) else { return }
        files.write(data, to: .traces)
        tracesAreUnwritten = false
        tracesWrittenAt = now
    }

    func trace(for account: AccountID) -> AccountUsageTrace? {
        book(&traces, .traces, { UsageTraceBook() })?.trace(for: account)
    }

    func traceBook() -> UsageTraceBook? {
        book(&traces, .traces, { UsageTraceBook() })
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
/// of the shape of the last few days for the verdict engine to say where a window is going.
///
/// ## The two calls
///
/// ```swift
/// // At start, before the first fetch. The panel draws from this instead of nothing.
/// let restored = history.restoreSnapshots()
///
/// // After every successful poll. Returns instantly; the write happens later, elsewhere.
/// history.record(snapshot, for: account.id, fleet: fleet)
/// ```
///
/// The `fleet` argument is the catalog rows — names, providers, order, whether each is signed
/// in — carried in from the main actor so the writer never reads the catalog itself. It is
/// what turns a sample into an answer: the brain runs on the books the instant they change,
/// and the assessment it produces arrives at `onAssessment`.
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

    /// Where each assessment goes. `AccountsStore` sets this and publishes what arrives.
    ///
    /// A property rather than an initialiser argument because the store owns the history and
    /// the history hands the store back an answer: two objects that are made in one order and
    /// wired in the other.
    public var onAssessment: (@MainActor (FleetAssessment) -> Void)?

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
        assessor: any FleetAssessing = SilentFleetAssessor(),
        sentences: @escaping @Sendable (FleetAssessment) -> RecommendationSentences = { _ in .none },
        clock: @escaping @Sendable () -> Date = { Date() },
        writeDeadline: Duration = UsageHistoryPolicy.writeDeadline,
        traceWriteDeadline: Duration = UsageHistoryPolicy.traceWriteDeadline
    ) {
        self.files = files
        self.clock = clock
        self.writeDeadline = writeDeadline
        writer = UsageHistoryWriter(
            files: files,
            assessor: assessor,
            sentences: sentences,
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
    public func restoreSnapshots() -> [AccountID: UsageSnapshot] {
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
    /// already scheduled, arms a single timer. Everything else — ring maintenance, the brain,
    /// encoding, the write — happens later and elsewhere.
    public func record(
        _ snapshot: UsageSnapshot,
        for account: AccountID,
        fleet: [FleetAccount]
    ) {
        post([.observed(account: account, snapshot: snapshot, at: clock())], fleet: fleet)
    }

    /// Drops one account's history. Call it where an account is removed.
    public func forget(_ account: AccountID, fleet: [FleetAccount] = []) {
        post([.forgotten(account)], fleet: fleet)
    }

    /// Asks the brain again over the books as they stand, without a new sample.
    ///
    /// A window resets, or a verdict boundary passes, and the right answer changes with
    /// nobody having polled anything. The assessment says when that is due through
    /// `nextReviewAt`; this is what the store calls when it arrives.
    public func reassess(fleet: [FleetAccount]) {
        let previous = chain
        let writer = writer
        let now = clock()
        chain = Task { [weak self] in
            await previous.value
            guard let assessment = await writer.assess(fleet: fleet, at: now) else { return }
            self?.publish(assessment)
        }
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

    /// One account's samples and completed windows — the verdict engine's read.
    ///
    /// Deliberately `async` and deliberately not on the launch path: it flushes first, then
    /// reads the trace book on the history queue. Everything the panel needs at launch is in
    /// `restoreSnapshots()`.
    public func trace(for account: AccountID) async -> AccountUsageTrace? {
        await flush()
        return await writer.trace(for: account)
    }

    /// Every account's traces. The verdict engine's fleet-wide read; the panel's card asks for one.
    public func traceBook() async -> UsageTraceBook? {
        await flush()
        return await writer.traceBook()
    }

    // MARK: - Scheduling

    /// Posts a change to the writer at once, and arms the file deadline behind it.
    private func post(_ mutations: [UsageHistoryMutation], fleet: [FleetAccount]) {
        let previous = chain
        let writer = writer
        let now = clock()
        chain = Task { [weak self] in
            await previous.value
            guard let assessment = await writer.apply(mutations, fleet: fleet, at: now) else {
                return
            }
            self?.publish(assessment)
        }
        armDeadline()
    }

    private func publish(_ assessment: FleetAssessment) {
        onAssessment?(assessment)
        // A reassessment can leave `recommendation.json` behind the books, so the timer is
        // armed for it too rather than only for a sample.
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
