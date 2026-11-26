import AppKit
import OSLog
import QotaFolioCore
import QotaFolioKit

/// The app, built once and held for as long as the process runs.
@MainActor
protocol AppRuntime: AnyObject {
    var ordinaryTerminationIsAllowed: Bool { get }
    func start()
    func revealPrimarySurface()
    func beginOrdinaryTermination() async
}

@MainActor
final class AppContainer {
    private let runtime: any AppRuntime

    private init(runtime: any AppRuntime) {
        self.runtime = runtime
    }

    static func make() async throws -> AppContainer {
        #if DEBUG
        // A debug build asked to show fixture accounts builds the app over them instead of over
        // the Keychain and the network: the same surfaces, the same panel, no grant. This is how
        // the panel is looked at and photographed on a Mac that holds no account.
        if let fixture = FixtureAppRuntime.make(environment: ProcessInfo.processInfo.environment) {
            return AppContainer(runtime: fixture)
        }
        #endif
        carryLegacySettings(identity: .current)
        return AppContainer(runtime: try await ProductionAppRuntime.make())
    }

    /// Carries version 1.0.0's settings into the home domain before anything reads a setting or Sparkle
    /// starts. A carry that cannot read the old file writes nothing, and the next launch tries again.
    private static func carryLegacySettings(identity: AppIdentity) {
        let log = Logger(subsystem: identity.bundleID, category: "settings")
        let file = identity.legacyPreferencesFile(home: .homeDirectory)
        do {
            if let keys = try LegacySettings.carry(from: file, into: .standard, domain: identity.preferencesDomain) {
                log.notice("The settings of 1.0.0 are carried: the home domain holds \(keys, privacy: .public) keys.")
            }
        } catch {
            // The domain and the code say why, and leave the path, with the user's name in it, out of the log.
            let reason = error as NSError
            log.error("The settings of 1.0.0 could not be read, and nothing was carried: \(reason.domain, privacy: .public) \(reason.code, privacy: .public)")
        }
    }

    var ordinaryTerminationIsAllowed: Bool {
        runtime.ordinaryTerminationIsAllowed
    }

    func start() {
        runtime.start()
    }

    /// Puts the panel in front of a user who just asked for an app that is already running.
    ///
    /// The app has no window of its own to raise, so a second launch and a Finder reopen both
    /// arrive at the delegate with nothing to do. This is what they do instead.
    func revealPrimarySurface() {
        runtime.revealPrimarySurface()
    }

    func beginOrdinaryTermination() async {
        await runtime.beginOrdinaryTermination()
    }
}
