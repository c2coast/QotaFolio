import Foundation

/// Version 1.0.0's settings, carried once into the domain this build reads.
///
/// Version 1.0.0 ran in the App Sandbox, so macOS kept its settings in a file inside its container. A process
/// outside the sandbox with the same identifier is served the home domain, which does not hold them. So the
/// carry copies the container's whole domain into the home domain, once, and leaves a marker there.
nonisolated enum LegacySettings {
    /// Set in the home domain when the carry is done. An empty home domain cannot be the marker: a stale home
    /// file can exist from a build that ran outside the sandbox long ago.
    static let markerKey = "legacy.settingsCarried.v1"

    nonisolated enum ReadError: Error, Equatable {
        case notADomain
    }

    /// The whole home domain after the carry, or nil when the carry writes nothing.
    ///
    /// Once the marker is set, the old file is never read again. Otherwise the container's domain replaces the
    /// home's whole, so the home holds exactly what 1.0.0 held and a stale key cannot outlive the carry. With no
    /// container file, as on a Mac that never ran 1.0.0, the carry only marks itself done.
    static func carried(home: [String: Any], legacy: () throws -> [String: Any]?) rethrows -> [String: Any]? {
        guard home[markerKey] == nil else { return nil }
        let marker: [String: Any] = [markerKey: true]
        return try (legacy() ?? home).merging(marker) { _, done in done }
    }

    /// The domain in a preferences file, or nil when there is no file.
    ///
    /// A file that cannot be read or is not a domain throws, and the carry writes nothing, so a later launch
    /// tries again.
    static func read(_ file: URL) throws -> [String: Any]? {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard let domain = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ReadError.notADomain
        }
        return domain
    }

    /// Carries the old file into `domain` of `defaults`, once. Returns how many keys the domain holds after
    /// a write, or nil when the carry wrote nothing.
    static func carry(from file: URL, into defaults: UserDefaults, domain: String) throws -> Int? {
        let home = defaults.persistentDomain(forName: domain) ?? [:]
        guard let next = try carried(home: home, legacy: { try read(file) }) else { return nil }
        defaults.setPersistentDomain(next, forName: domain)
        return next.count
    }
}
