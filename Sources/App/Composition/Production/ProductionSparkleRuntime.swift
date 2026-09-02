import Foundation
import Sparkle
import QotaFolioCore
import QotaFolioKit

nonisolated enum ProductionUpdateSecurityError: Error, Equatable, Sendable {
    case rollbackBlocked(offered: Int, highestObserved: Int)
    case malformedVersionString
}

@MainActor
final class ProductionSparkleUpdateDelegate: NSObject, SPUUpdaterDelegate {
    private static let highestObservedBuildKey = "update.highestObservedBuild"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        guard let highest = appcast.items.compactMap({ Int($0.versionString) }).max(),
              highest > highestObservedBuild else {
            return
        }
        defaults.set(highest, forKey: Self.highestObservedBuildKey)
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        guard let offered = Int(updateItem.versionString) else {
            throw ProductionUpdateSecurityError.malformedVersionString
        }
        let highest = highestObservedBuild
        guard offered >= highest else {
            throw ProductionUpdateSecurityError.rollbackBlocked(
                offered: offered,
                highestObserved: highest
            )
        }
    }

    private var highestObservedBuild: Int {
        defaults.integer(forKey: Self.highestObservedBuildKey)
    }

    #if DEBUG
    // MARK: - The development feed door
    //
    // Everything from here to the `#endif` exists only in a Debug build. Not the delegate
    // method, not the function it calls, not even the name of the environment variable: a
    // Release binary does not contain the string `QOTAFOLIO_DEBUG_FEED_URL` anywhere, and
    // the release lane's `release-feed-url` gate proves that by reading the archived binary
    // rather than by reading this comment.

    /// The environment variable a development build reads its appcast feed from.
    ///
    /// `Tools/release/qotafolio_release.py` reads this literal out of this file so that the
    /// gate and the code cannot drift apart. Renaming it here is safe; changing the shape of
    /// this line fails the gate loudly rather than leaving it proving nothing.
    nonisolated static let developmentFeedURLVariable = "QOTAFOLIO_DEBUG_FEED_URL"

    /// A feed served from this Mac, or nothing.
    ///
    /// The one shape this accepts is plain HTTP on the loopback address, because that is the
    /// whole of what the door is for: a development build updating itself from an appcast and
    /// an archive sitting on the same machine, before the public repository exists. Anything
    /// else -- a hostname, a LAN address, an `https` staging server -- is refused, so the door
    /// cannot quietly become "point a build somewhere else". A feed on a real host belongs in
    /// `SUFeedURL`, where every build reads it and anyone can see it in the shipped bundle.
    ///
    /// Nothing is relaxed by taking this door. Sparkle still requires the whole feed to carry
    /// an EdDSA signature (`SURequireSignedFeed`), still verifies the archive before it is
    /// unpacked (`SUVerifyUpdateBeforeExtraction`), and still checks both against the one
    /// public key in this bundle's `Info.plist`. A local feed can offer an update; it cannot
    /// offer one this app will install unless it was signed with the real private key.
    nonisolated static func developmentFeedURL(from environment: [String: String]) -> String? {
        guard let value = environment[developmentFeedURLVariable],
              let url = URL(string: value),
              url.scheme == "http",
              url.host == "127.0.0.1"
        else { return nil }
        return value
    }

    /// Sparkle asks the delegate before it asks the `Info.plist`, and only a Debug build has one.
    ///
    /// `-[SPUUpdater retrieveFeedURL:]` gives the delegate first refusal and falls back to
    /// `SUFeedURL` when the delegate answers `nil`. So a Debug build launched with no variable
    /// set -- from Xcode, from the Finder, by any builder who is not running the update test --
    /// reads the same feed a Release build reads, and a Release build has no delegate method
    /// here at all for Sparkle to ask.
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.developmentFeedURL(from: ProcessInfo.processInfo.environment)
    }
    #endif
}

/// Sparkle's configuration-phase failures, reduced to a machine code the redacted log carries.
///
/// `NSError.localizedDescription` is never read here. Every message Sparkle writes for these
/// codes interpolates the host bundle's display name, and three of them interpolate a file
/// path — see `-[SPUUpdater checkIfConfiguredProperlyAndRequireFeedURL:validateXPCServices:error:]`.
/// The redaction doctrine keeps both out of diagnostics, so the code is what is written and
/// the message is what is dropped. Sparkle logs its own full text under its own subsystem for
/// anyone who wants it.
nonisolated enum SparkleStartDiagnosis {
    /// The seven codes `SUErrors.h` groups under "Configuration phase errors".
    ///
    /// Those seven are the whole of what `-[SPUUpdater startUpdater:]` can report: it
    /// validates the framework, the bundle identifier, the bundle version, the enabled XPC
    /// services, the feed URL and the EdDSA public key, and returns before any network
    /// activity. A code outside them means Sparkle refused the start for a reason its own
    /// header does not describe, which earns its own name rather than a silent bucket.
    static func machineCode(for error: any Error) -> StaticString {
        let error = error as NSError
        guard error.domain == SUSparkleErrorDomain,
              let code = SUError(rawValue: OSStatus(error.code))
        else {
            return "sparkle-start-foreign-error"
        }

        switch code {
        case .noPublicDSAFoundError: return "sparkle-start-no-public-key"
        case .insufficientSigningError: return "sparkle-start-insufficient-signing"
        case .insecureFeedURLError: return "sparkle-start-insecure-feed-url"
        case .invalidFeedURLError: return "sparkle-start-invalid-feed-url"
        case .invalidUpdaterError: return "sparkle-start-invalid-updater"
        case .invalidHostBundleIdentifierError: return "sparkle-start-no-bundle-identifier"
        case .invalidHostVersionError: return "sparkle-start-invalid-host-version"
        default: return "sparkle-start-unexpected-phase"
        }
    }
}

@MainActor
final class ProductionSparkleControllerSource: SettingsUpdaterSource {
    private let controller: SPUStandardUpdaterController
    private let log: any RedactingLog

    /// Set only by `start()`, and only when `SPUUpdater.start()` returned without throwing.
    ///
    /// Sparkle publishes no property that answers this. `canCheckForUpdates` is `false`
    /// before the updater starts and `false` again while it is busy, which is exactly the
    /// ambiguity `updateCheckAvailability` exists to resolve.
    private var updaterIsRunning = false

    init(
        controller: SPUStandardUpdaterController,
        log: any RedactingLog
    ) {
        self.controller = controller
        self.log = log
    }

    /// Starts Sparkle at launch, through the throwing API, and owns the failure.
    ///
    /// `SPUStandardUpdaterController.startUpdater()` is the wrong door. Its own header says it
    /// "alerts the user that the app is misconfigured and to contact the developer", and its
    /// implementation runs that alert modally one second later — unconditionally, with no
    /// delegate to intercept it, no user-driver override and no return value to inspect.
    /// `SPUUpdater`'s own `-startUpdater:` reports the same failure as an error and shows
    /// nothing. Swift spells that one `start()`: the importer consumes the trailing `NSError**`
    /// and then drops the redundant "Updater" from a method on `SPUUpdater`. So the two doors
    /// have different names in Swift, and `startUpdater()` is always the one with the modal.
    ///
    /// The user sees nothing at launch, because there is nothing here a user can act on. Every
    /// failure this can report is a fault in the bundle we shipped. The failure goes to the
    /// unified log as a machine code, and the Settings tab says the one sentence that is true:
    /// this copy cannot update itself.
    ///
    /// It runs at launch rather than on the first account, so `updateCheckAvailability` reads an
    /// answer instead of *predicting* one it cannot know — and a "Check for Updates…" item is
    /// never enabled over an updater that has never run.
    func start() {
        guard !updaterIsRunning else { return }
        do {
            try controller.updater.start()
            updaterIsRunning = true
        } catch {
            log.emit(
                DiagEvent(
                    provider: nil,
                    operation: .updateCheck,
                    outcome: .permanent,
                    machineErrorCode: SparkleStartDiagnosis.machineCode(for: error)
                )
            )
        }
    }

    /// A reading, not a prediction. The updater has already been started or already failed to
    /// start by the time anything asks.
    var updateCheckAvailability: UpdateCheckAvailability {
        guard updaterIsRunning else { return .unavailable }
        return controller.updater.canCheckForUpdates ? .ready : .busy
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// `canCheckForUpdates` is the property a successful start flips, synchronously, inside
    /// `startUpdater:`. Observing it is therefore what tells a Settings surface built before
    /// `start()` ran that the updater came up.
    func observeStateChanges(
        _ handler: @MainActor @Sendable @escaping () -> Void
    ) -> any SettingsIntegrationObservation {
        let updater = controller.updater
        let tokens = [
            updater.observe(\.canCheckForUpdates) { _, _ in
                Task { @MainActor in handler() }
            },
            updater.observe(\.automaticallyChecksForUpdates) { _, _ in
                Task { @MainActor in handler() }
            },
            updater.observe(\.automaticallyDownloadsUpdates) { _, _ in
                Task { @MainActor in handler() }
            },
            updater.observe(\.sessionInProgress) { _, _ in
                Task { @MainActor in handler() }
            },
        ]
        return ProductionSparkleObservation(tokens: tokens)
    }
}

@MainActor
private final class ProductionSparkleObservation: SettingsIntegrationObservation {
    private var tokens: [NSKeyValueObservation]

    init(tokens: [NSKeyValueObservation]) {
        self.tokens = tokens
    }

    func cancel() {
        tokens.forEach { $0.invalidate() }
        tokens.removeAll()
    }
}
