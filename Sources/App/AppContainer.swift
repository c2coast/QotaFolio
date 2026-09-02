import AppKit
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
        return AppContainer(runtime: try await ProductionAppRuntime.make())
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
