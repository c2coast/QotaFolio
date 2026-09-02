import Foundation

/// Everything the brain is given, in one value.
///
/// A struct rather than four arguments so that anything the assessment is found to need next
/// arrives as a field here and changes no call site.
public nonisolated struct FleetAssessmentRequest: Sendable {
    /// Every sample this app has kept, per account per window.
    public let traces: UsageTraceBook
    /// The last successful poll per account.
    public let snapshots: UsageSnapshotBook
    /// The catalog rows, in panel order.
    public let fleet: [FleetAccount]
    /// The snapshot book's clock. Everything the assessment says is relative to this.
    public let now: Date
    /// The person's own clock. Hour of week is a fact about their day, not about UTC.
    public let timeZone: TimeZone

    public init(
        traces: UsageTraceBook,
        snapshots: UsageSnapshotBook,
        fleet: [FleetAccount],
        now: Date,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.traces = traces
        self.snapshots = snapshots
        self.fleet = fleet
        self.now = now
        self.timeZone = timeZone
    }
}

/// The one call the history writer makes into the brain.
///
/// Pure and `nonisolated`: it runs on the writer actor after every poll, over books that are
/// already in memory, and it touches no file and no clock of its own.
public nonisolated protocol FleetAssessing: Sendable {
    func assess(_ request: FleetAssessmentRequest) -> FleetAssessment
}

/// The brain before there is one: it names the fleet and says nothing about it.
///
/// Not a fallback. The shape it holds — an assessment that says nothing — is the same shape
/// `FleetBrain` produces in the five cases where staying quiet is the honest answer.
public nonisolated struct SilentFleetAssessor: FleetAssessing {
    public init() {}

    public func assess(_ request: FleetAssessmentRequest) -> FleetAssessment {
        .silent(at: request.now, accounts: request.fleet, timeZone: request.timeZone)
    }
}
