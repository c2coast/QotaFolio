import Foundation
import QotaFolioModel
import Testing

/// The names the release owns, written out by hand from version 1.0.0, and the development build's apart
/// from every one of them.
struct AppIdentityTests {
    let release = AppIdentity(bundleID: "net.c2coast.QotaFolio")
    let development = AppIdentity(bundleID: "net.c2coast.QotaFolio.dev")
    let home = URL(filePath: "/home-of-a-test", directoryHint: .isDirectory)

    @Test("The release keeps the Keychain service, the group and the domain that version 1.0.0 used")
    func theReleaseKeepsTheNamesOfVersionOne() {
        #expect(release.keychainService == "net.c2coast.QotaFolio.oauth-token-set")
        #expect(release.appGroupIdentifier == "NCCKY76LD4.group.net.c2coast.QotaFolio")
        #expect(release.preferencesDomain == "net.c2coast.QotaFolio")
        #expect(release.statusItemAutosaveName == "net.c2coast.QotaFolio.status-item")
    }

    @Test("The release's lease is in its support folder, and 1.0.0's settings are in its container")
    func theReleaseFindsItsFilesUnderTheHomeFolder() {
        #expect(release.leaseFile(home: home).path
            == "/home-of-a-test/Library/Application Support/net.c2coast.QotaFolio/single-instance.lock")
        #expect(release.legacyPreferencesFile(home: home).path
            == "/home-of-a-test/Library/Containers/net.c2coast.QotaFolio/Data/Library/Preferences/net.c2coast.QotaFolio.plist")
    }

    @Test("Remove My Data takes these places of the release, and never 1.0.0's container itself")
    func removeMyDataTakesTheReleasesPlaces() {
        let container = "Library/Containers/net.c2coast.QotaFolio/Data/"
        let group = "Library/Group Containers/NCCKY76LD4.group.net.c2coast.QotaFolio/Library/"
        let expected = [
            "Library/Application Support/net.c2coast.QotaFolio",
            "Library/Caches/net.c2coast.QotaFolio",
            "Library/HTTPStorages/net.c2coast.QotaFolio",
            "Library/HTTPStorages/net.c2coast.QotaFolio.binarycookies",
            "Library/Preferences/net.c2coast.QotaFolio.plist",
            container + "Library/Application Support/net.c2coast.QotaFolio",
            container + "Library/Caches/net.c2coast.QotaFolio",
            container + "Library/HTTPStorages/net.c2coast.QotaFolio",
            container + "Library/HTTPStorages/net.c2coast.QotaFolio.binarycookies",
            container + "Library/Preferences/net.c2coast.QotaFolio.plist",
            group + "Application Support/QotaFolio",
            group + "Preferences/NCCKY76LD4.group.net.c2coast.QotaFolio.plist",
        ]
        #expect(release.ownedPlaces(home: home).map(\.path) == expected.map { "/home-of-a-test/" + $0 })
    }

    @Test("Every name a development build owns differs from the release's")
    func aDevelopmentBuildOwnsNoNameOfTheRelease() {
        #expect(development.keychainService != release.keychainService)
        #expect(development.appGroupIdentifier != release.appGroupIdentifier)
        #expect(development.preferencesDomain != release.preferencesDomain)
        #expect(development.statusItemAutosaveName != release.statusItemAutosaveName)
        #expect(development.leaseFile(home: home) != release.leaseFile(home: home))
        #expect(development.legacyPreferencesFile(home: home) != release.legacyPreferencesFile(home: home))
    }

    @Test("Remove My Data in a development build reaches no place of the release")
    func removingADevelopmentBuildLeavesTheRelease() {
        let releasePlaces = release.ownedPlaces(home: home).map(\.path)
        for place in development.ownedPlaces(home: home).map(\.path) {
            for kept in releasePlaces {
                #expect(place != kept && !place.hasPrefix(kept + "/") && !kept.hasPrefix(place + "/"))
            }
        }
    }
}
