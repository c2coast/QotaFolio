import Foundation
import OSLog
import QotaFolioCore

nonisolated final class ProductionRedactingLogger: RedactingLog, Sendable {
    // The running bundle's identifier, not the shipping one, so a `.dev` build's lines land in
    // its own subsystem: `log stream --predicate 'subsystem == "net.c2coast.QotaFolio.dev"'` —
    // the documented way to watch a development build — sees them.
    private let logger = Logger(
        subsystem: AppIdentity.current.bundleID,
        category: "runtime"
    )

    func emit(_ event: DiagEvent) {
        let provider = event.provider?.rawValue ?? "none"
        let host = event.host?.description ?? "none"
        let path = event.path?.description ?? "none"
        let status = event.httpStatus.map(String.init) ?? "none"
        let duration = event.durationMS.map(String.init) ?? "none"
        let size = event.sizeBucket.map(String.init) ?? "none"
        let schema = event.schemaFamily?.description ?? "none"
        let machineCode = event.machineErrorCode?.description ?? "none"
        let revision = event.revision?.rawValue.uuidString ?? "none"
        let account = event.accountHash ?? "none"

        logger.log(
            level: Self.level(for: event),
            "provider=\(provider, privacy: .public) operation=\(event.operation.rawValue, privacy: .public) outcome=\(event.outcome.rawValue, privacy: .public) host=\(host, privacy: .public) path=\(path, privacy: .public) status=\(status, privacy: .public) duration_ms=\(duration, privacy: .public) size_bucket=\(size, privacy: .public) schema=\(schema, privacy: .public) code=\(machineCode, privacy: .public) revision=\(revision, privacy: .public) account=\(account, privacy: .public)"
        )
    }

    /// The level is how much the line matters, not whether the operation failed.
    ///
    /// `.info` is a memory-only level: `log show` reads the persisted store, so an `.info`
    /// line is gone by the time anyone looks. That is right for a poll, which happens every
    /// few minutes and whose last result is on screen anyway. It is wrong for the one-time
    /// move of a user's accounts into the App Group container, which happens once in an
    /// install's life and is the first thing anybody asks about afterwards.
    private static func level(for event: DiagEvent) -> OSLogType {
        switch event.outcome {
        case .ok:
            event.operation == .containerMigrate ? .default : .info
        case .transient, .refused:
            .default
        case .permanent, .contractViolation:
            .error
        }
    }
}
