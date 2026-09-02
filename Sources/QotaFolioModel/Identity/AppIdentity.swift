import Foundation

/// Every place this app keeps something, derived from the one thing that decides them all.
///
/// macOS gives a sandboxed app its container, its implicit Keychain access group and its
/// preferences domain from its bundle identifier. Every one of those locations is derived
/// here rather than written out as a literal beside it, so no refactor can change one and
/// leave the user's data stranded under a name nothing reads any more. The identity has
/// exactly one degree of freedom.
///
/// `AppIdentityDerivationTests` pins the derived values for `net.c2coast.QotaFolio` against
/// the literals that are on an installed app's disk today. That test is what stands between a
/// tidy-up and two accounts that have to be authorised again through a browser.
///
/// It also buys development isolation for one build setting. Debug builds carry
/// `net.c2coast.QotaFolio.dev`, so they get their own container, their own defaults, their own
/// access group and their own Keychain service — a developer can run what they built without
/// touching the installed app's state.
public nonisolated struct AppIdentity: Equatable, Sendable {
    /// The identifier the shipping app is signed and distributed under.
    ///
    /// Only a bundle with no identifier at all falls back to this, which no app bundle does.
    public static let productionBundleID = "net.c2coast.QotaFolio"

    /// The Apple Developer team the shipping app is signed by.
    ///
    /// The one thing besides the bundle identifier that names a location. macOS requires an
    /// App Group to carry its team's prefix — the plain `group.…` form resolves to a container
    /// root the system treats as protected — so the team identifier is part of the group's
    /// name and cannot be derived from anything else the process knows.
    public static let shippingTeamIdentifier = "NCCKY76LD4"

    /// The Info.plist key naming the team a build was signed by.
    ///
    /// It carries `$(DEVELOPMENT_TEAM)`, which is the same build setting
    /// `Sources/QotaFolio.entitlements` spells the App Group with — so whoever builds this is
    /// signed for a group their own build can open. That is what lets someone who is not us
    /// clone the repository, give their own team, and run what they built.
    /// `AppIdentityDerivationTests` reads both files and checks they still agree, because a
    /// rename in either place that the other does not follow leaves the app with no group
    /// container at all and nothing else would say a word.
    public static let teamIdentifierKey = "QotaFolioTeamIdentifier"

    public let bundleID: String
    public let teamIdentifier: String

    public init(bundleID: String, teamIdentifier: String = AppIdentity.shippingTeamIdentifier) {
        self.bundleID = bundleID
        self.teamIdentifier = teamIdentifier
    }

    /// The identity a bundle declares: the host it names, else the bundle it is, and the team
    /// it was signed by.
    public init(bundle: Bundle) {
        func declared(_ key: String) -> String? {
            (bundle.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(
            bundleID: declared(Self.hostBundleIdentifierKey)
                ?? bundle.bundleIdentifier
                ?? Self.productionBundleID,
            teamIdentifier: declared(Self.teamIdentifierKey) ?? Self.shippingTeamIdentifier
        )
    }

    /// The Info.plist key an extension uses to say whose files it reads.
    ///
    /// An extension is its own bundle with its own identifier, so `Bundle.main.bundleIdentifier`
    /// in the widget extension is `…Widgets` — and the App Group derived from that would be a
    /// container nothing writes to. The extension's Info.plist carries the host app's
    /// identifier under this key, set from the same build setting the app's own identifier is.
    public static let hostBundleIdentifierKey = "QotaFolioHostBundleIdentifier"

    /// This process's identity.
    public static let current = AppIdentity(bundle: .main)

    /// The Keychain service every OAuth credential item is filed under.
    ///
    /// One `kSecClassGenericPassword` item per account sits under this service. Uninstall
    /// deletes the service in one `SecItemDelete`, so this string is both where credentials
    /// live and the whole of what removing them means.
    public var keychainService: String { "\(bundleID).oauth-token-set" }

    /// The App Group container the app shares with the widget extension, the menu-bar Control
    /// and the `qota` command.
    ///
    /// Every one of those is a separate process, and a separate process cannot open another's
    /// sandbox container. This is the one place all of them can read.
    public var appGroupIdentifier: String { "\(teamIdentifier).group.\(bundleID)" }

    /// The `UserDefaults` suite name, which for an app is its bundle identifier.
    public var preferencesDomain: String { bundleID }

    /// The status item's `autosaveName`, under which AppKit records its position.
    public var statusItemAutosaveName: String { "\(bundleID).status-item" }

    /// Relative to the user's home directory.
    public var sandboxContainerRelativePath: String { "Library/Containers/\(bundleID)" }

    /// Relative to the user's home directory.
    public var sandboxDataRelativePath: String { sandboxContainerRelativePath + "/Data" }

    /// Relative to the sandbox `Data` directory. Holds the account catalog and the lease.
    public var applicationSupportRelativePath: String {
        "Library/Application Support/\(bundleID)"
    }

    /// Relative to the sandbox `Data` directory. Sparkle's download and extraction cache.
    public var sparkleCacheRelativePath: String {
        "Library/Caches/\(bundleID)/org.sparkle-project.Sparkle"
    }

    /// The exclusive-lock file that makes a second launch ring the first instead of exiting.
    public var singleInstanceLeaseLeafName: String { "single-instance.lock" }

    /// The lease, relative to the sandbox `Data` directory.
    public var singleInstanceLeaseRelativeToData: String {
        applicationSupportRelativePath + "/" + singleInstanceLeaseLeafName
    }
}

/// Absolute owned locations under one current-user sandbox `Data` directory.
public nonisolated struct AppIdentityLocations: Equatable, Sendable {
    public let dataDirectoryPath: String
    public let applicationSupportDirectoryPath: String
    public let singleInstanceLeasePath: String
    public let sparkleCachePath: String

    public init(identity: AppIdentity, dataDirectoryPath: String) {
        var data = dataDirectoryPath
        while data.count > 1, data.hasSuffix("/") {
            data.removeLast()
        }
        self.dataDirectoryPath = data
        applicationSupportDirectoryPath = data + "/" + identity.applicationSupportRelativePath
        singleInstanceLeasePath = data + "/" + identity.singleInstanceLeaseRelativeToData
        sparkleCachePath = data + "/" + identity.sparkleCacheRelativePath
    }
}

/// The one derivation of this process's sandbox container `Data` directory.
///
/// The sandbox decides where the container is, so `FileManager` answers that question and
/// `AppIdentity` decides every owned leaf below it. Nothing hardcodes a path.
public nonisolated enum OwnedContainerDataDirectory {
    public enum ResolutionError: Error, Equatable, Sendable {
        case notAContainerDataDirectory
    }

    public static func resolve(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        guard applicationSupport.lastPathComponent == "Application Support",
              applicationSupport.deletingLastPathComponent().lastPathComponent == "Library" else {
            throw ResolutionError.notAContainerDataDirectory
        }
        return applicationSupport
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
