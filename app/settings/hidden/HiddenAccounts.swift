import Foundation
import QotaFolioModel

/// The accounts a person hid in Settings. The panel, the menu-bar batteries and `qota status` leave them out.
///
/// The app keeps the list in its preferences domain, and `qota` reads that domain by its name. Both read the key and
/// the list's shape here, so the two cannot drift apart. Version 1.0.0 wrote the same key in the same shape.
nonisolated enum HiddenAccounts {
    static let key = "settings.accountVisibility.hiddenAccountIDs.v1"

    /// The ids in a stored list. A string that is not an id is skipped.
    static func ids(stored: [String]?) -> Set<AccountID> {
        Set((stored ?? []).compactMap { UUID(uuidString: $0).map(AccountID.init(rawValue:)) })
    }

    /// The list to store: each id in lower case, sorted, so one set always writes the same list.
    static func stored(_ ids: Set<AccountID>) -> [String] {
        ids.map { $0.rawValue.uuidString.lowercased() }.sorted()
    }

    /// The hidden ids in the domain of `defaults`.
    static func ids(in defaults: UserDefaults) -> Set<AccountID> {
        ids(stored: defaults.stringArray(forKey: key))
    }

    /// Stores `ids` in the domain of `defaults`.
    static func store(_ ids: Set<AccountID>, in defaults: UserDefaults) {
        defaults.set(stored(ids), forKey: key)
    }
}

extension SurfaceReading {
    /// The same reading without the accounts in `hidden`. The other accounts keep their order.
    nonisolated func hiding(_ hidden: Set<AccountID>) -> SurfaceReading {
        SurfaceReading(accounts: accounts.filter { !hidden.contains($0.id) }, readAt: readAt)
    }
}
