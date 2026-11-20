import Foundation

/// Every name this app owns, derived from the one thing that decides them all: the bundle identifier.
///
/// The Keychain service, the group, the preferences domain and every place on disk follow from it, so
/// no refactor can change one and leave the user's data under a name nothing reads any more. A Debug
/// build carries `net.c2coast.QotaFolio.dev`, so it gets its own of each, and a developer can run what
/// they built without touching the installed app.
///
/// `app/main/tests/AppIdentityTests.swift` pins the release names against the ones version 1.0.0 used.
/// That test is what stands between a tidy-up and two accounts that have to sign in again.
public nonisolated struct AppIdentity: Equatable, Sendable {
    /// The identifier the shipping app is signed and distributed under.
    public static let productionBundleID = "net.c2coast.QotaFolio"

    /// The Apple Developer team the shipping app is signed by.
    ///
    /// The one thing besides the bundle identifier that names a place. macOS requires an App Group to
    /// carry its team's prefix, so the team is part of the group's name and cannot be derived.
    public static let shippingTeamIdentifier = "NCCKY76LD4"

    /// The Info.plist key naming the team a build was signed by.
    ///
    /// It carries `$(DEVELOPMENT_TEAM)`, the same build setting `app/main/QotaFolio.entitlements` spells
    /// the App Group with, so whoever builds this is signed for a group their own build can open.
    public static let teamIdentifierKey = "QotaFolioTeamIdentifier"

    public let bundleID: String
    public let teamIdentifier: String

    public init(bundleID: String, teamIdentifier: String = AppIdentity.shippingTeamIdentifier) {
        self.bundleID = bundleID
        self.teamIdentifier = teamIdentifier
    }

    /// The identity a bundle declares: the bundle it is, and the team it was signed by.
    public init(bundle: Bundle) {
        let team = (bundle.object(forInfoDictionaryKey: Self.teamIdentifierKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            bundleID: bundle.bundleIdentifier ?? Self.productionBundleID,
            teamIdentifier: team ?? Self.shippingTeamIdentifier
        )
    }

    /// This process's identity.
    public static let current = AppIdentity(bundle: .main)

    /// The Keychain service every OAuth credential item is filed under. Remove My Data deletes the
    /// service whole.
    public var keychainService: String { "\(bundleID).oauth-token-set" }

    /// The App Group whose container holds the history and the catalog of version 1.0.0, which the app
    /// and the `qota` command read.
    public var appGroupIdentifier: String { "\(teamIdentifier).group.\(bundleID)" }

    /// The `UserDefaults` domain, which for an app is its bundle identifier.
    public var preferencesDomain: String { bundleID }

    /// The status item's `autosaveName`, under which AppKit records its place in the menu bar.
    public var statusItemAutosaveName: String { "\(bundleID).status-item" }

    /// The single-instance lease, in the support folder.
    public func leaseFile(home: URL) -> URL {
        home.appending(path: supportFolderPath + "/single-instance.lock", directoryHint: .notDirectory)
    }

    /// The preferences file of version 1.0.0, which macOS kept inside its sandbox container.
    public func legacyPreferencesFile(home: URL) -> URL {
        home.appending(path: legacyDataPath + "/" + preferencesPath, directoryHint: .notDirectory)
    }

    /// Every place Remove My Data takes away: what this build writes outside the sandbox, the same
    /// places inside version 1.0.0's container, and the group's files and preferences.
    ///
    /// Never the container itself: its `Data` folder holds links to the user's own Desktop, Documents and
    /// Downloads.
    public func ownedPlaces(home: URL) -> [URL] {
        let outside = [
            supportFolderPath,
            "Library/Caches/\(bundleID)",
            "Library/HTTPStorages/\(bundleID)",
            "Library/HTTPStorages/\(bundleID).binarycookies",
            preferencesPath,
        ]
        let group = "Library/Group Containers/\(appGroupIdentifier)/Library"
        let paths = outside + outside.map { legacyDataPath + "/" + $0 } + [
            "\(group)/Application Support/\(SharedContainer.ownedDirectoryName)",
            "\(group)/Preferences/\(appGroupIdentifier).plist",
        ]
        return paths.map { home.appending(path: $0) }
    }

    private var supportFolderPath: String { "Library/Application Support/\(bundleID)" }
    private var preferencesPath: String { "Library/Preferences/\(preferencesDomain).plist" }
    private var legacyDataPath: String { "Library/Containers/\(bundleID)/Data" }
}
