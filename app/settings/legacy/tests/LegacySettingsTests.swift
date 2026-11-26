import Foundation
import Testing

/// The carry, run on a file in the shape of version 1.0.0's: its nine keys, with invented values.
struct LegacySettingsTests {
    let folder: URL
    let file: URL

    /// What 1.0.0 keeps: the appearance, what the strip shows, the hidden accounts, the hiding of names while
    /// the screen is shared, the alerts already delivered, the rollback floor, and three keys of Sparkle's.
    let version1: [String: Any] = [
        "settings.general.appearance.v1": "dark",
        "settings.general.stripShows.v1": "week",
        "settings.accountVisibility.hiddenAccountIDs.v1": ["account-b"],
        "settings.privacy.hideNamesWhileShared.v1": false,
        "alerts.delivered.v1": ["account-a|week|90"],
        "update.highestObservedBuild": 100,
        "SUHasLaunchedBefore": true,
        "SULastCheckTime": Date(timeIntervalSince1970: 1_700_000_000),
        "SUUpdateGroupIdentifier": 4_242,
    ]

    init() {
        folder = FileManager.default.temporaryDirectory.appending(path: "carry-\(UUID().uuidString)")
        file = folder.appending(path: "Library/Containers/net.example.app/Data/Library/Preferences/net.example.app.plist")
    }

    @Test("After the first run the home domain holds every key of 1.0.0 with its value, and the second run writes nothing")
    func theCarryRunsOnce() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(version1)

        let first = try #require(try LegacySettings.carried(home: [:], legacy: { try LegacySettings.read(file) }))
        #expect(Set(first.keys) == Set(version1.keys).union([LegacySettings.markerKey]))
        for (key, value) in version1 {
            #expect(NSDictionary(dictionary: first).object(forKey: key).map { ($0 as AnyObject).isEqual(value) } == true, "\(key)")
        }

        var readsAfterTheFirst = 0
        let second = try LegacySettings.carried(home: first) {
            readsAfterTheFirst += 1
            return try LegacySettings.read(file)
        }
        #expect(second == nil)
        #expect(readsAfterTheFirst == 0)
    }

    @Test("1.0.0's values win over a stale home domain, and a key only the stale domain held is gone")
    func theContainerWins() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(version1)
        let stale: [String: Any] = ["settings.general.appearance.v1": "light", "stale.key": 1]

        let carried = try #require(try LegacySettings.carried(home: stale, legacy: { try LegacySettings.read(file) }))
        #expect(carried["settings.general.appearance.v1"] as? String == "dark")
        #expect(carried["stale.key"] == nil)
    }

    @Test("On a Mac that never ran 1.0.0, the carry keeps the home domain and marks itself done")
    func noContainerMarksItselfDone() throws {
        let home: [String: Any] = ["settings.general.appearance.v1": "light"]
        let carried = try #require(try LegacySettings.carried(home: home, legacy: { try LegacySettings.read(file) }))
        #expect(carried["settings.general.appearance.v1"] as? String == "light")
        #expect(carried[LegacySettings.markerKey] as? Bool == true)
        #expect(carried.count == 2)
    }

    @Test("A file that holds no domain writes nothing, so a later launch tries again")
    func aFileThatIsNoDomainWritesNothing() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(["not", "a", "domain"])
        #expect(throws: LegacySettings.ReadError.notADomain) {
            _ = try LegacySettings.carried(home: [:], legacy: { try LegacySettings.read(file) })
        }

        try Data("not a property list".utf8).write(to: file)
        #expect(throws: (any Error).self) {
            _ = try LegacySettings.carried(home: [:], legacy: { try LegacySettings.read(file) })
        }
    }

    private func write(_ plist: Any) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: file)
    }
}
