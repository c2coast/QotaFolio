import Foundation

import QotaFolioCore
import Security

public nonisolated protocol CredentialItemStore: Sendable {
    func read(_ reference: CredentialReference) throws -> Data?
    func upsert(_ data: Data, for reference: CredentialReference) throws
    func delete(_ reference: CredentialReference) throws
    /// Removes **every** item this app owns, in one call. Not the first one. Not one per call
    /// until the store says it is empty.
    ///
    /// It is a requirement of the protocol and not a convenience on one implementation for two
    /// reasons, and both of them are about what a caller must be able to promise a user.
    ///
    /// A caller must be able to wipe the store **without first enumerating it**. An item this
    /// app cannot list, read or decode — a locked keychain, an envelope from a schema this
    /// build has never seen — still has to go, and it cannot go if the wipe is a loop over
    /// whatever the reading half managed to find.
    ///
    /// And its correctness cannot be seen in a one-item test. See
    /// `KeychainTokenStore.deleteAllOwnedItems()` for the platform behaviour that makes that
    /// true, which is measured rather than assumed.
    ///
    /// Removing nothing is a success: there was nothing to remove.
    func deleteAllOwnedItems() throws
    func enumerateReferences() throws -> Set<CredentialReference>
}

nonisolated enum KeychainError: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case unavailable
    case unexpected(OSStatus)
    case malformedResult

    var description: String {
        switch self {
        case .unavailable:
            "keychain unavailable"
        case .unexpected(let status):
            "keychain operation failed with status \(status)"
        case .malformedResult:
            "keychain returned malformed attributes"
        }
    }

    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}

public nonisolated struct KeychainTokenStore: CredentialItemStore {
    private let service: String
    private let label: String

    public init() {
        service = AppIdentity.current.keychainService
        label = "QotaFolio OAuth credentials"
    }

    init(syntheticTestNamespace identifier: UUID) {
        service = "\(AppIdentity.current.bundleID).synthetic-test.\(identifier.uuidString).oauth-token-set"
        label = "QotaFolio synthetic test credentials"
    }

    var serviceIdentifierForTesting: String { service }

    public func read(_ reference: CredentialReference) throws -> Data? {
        var query = exactQuery(reference)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.malformedResult
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw mappedError(status)
        }
    }

    public func upsert(_ data: Data, for reference: CredentialReference) throws {
        let query = exactQuery(reference)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw mappedError(updateStatus)
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = label

        let addStatus = SecItemAdd(add as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let retryStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw mappedError(retryStatus)
            }
        default:
            throw mappedError(addStatus)
        }
    }

    public func delete(_ reference: CredentialReference) throws {
        let status = SecItemDelete(exactQuery(reference) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw mappedError(status)
        }
    }

    /// Deletes every credential this app owns, in one call.
    ///
    /// **`kSecMatchLimitAll` is load-bearing and must not be removed.** The common advice is
    /// that `SecItemDelete` takes no match limit and removes everything matching its query.
    /// That is true of the data-protection keychain. This app uses the macOS file-based
    /// keychain — it never sets `kSecUseDataProtectionKeychain`, because doing so is what
    /// produced -34018 — and there the default limit is ONE. Without this line the call
    /// returns `errSecSuccess` having deleted a single item, and a user with two accounts who
    /// pressed "Remove My Data" would be left with one credential still in their Keychain and
    /// an app telling them everything was gone. `theCredentialsAreDeleted` writes two items
    /// and is the test that catches it.
    ///
    /// MEASURED on this Mac, macOS 26, two generic passwords in one service: the query WITHOUT
    /// the match limit returns `errSecSuccess` and leaves ONE item behind; the same query WITH
    /// it returns `errSecSuccess` and leaves NONE.
    /// `aWholeServiceDeleteWithoutTheMatchLimitLeavesAnItemBehind` is that measurement, kept as
    /// a test so the day the platform changes is the day someone reads this comment rather than
    /// the day a user keeps a credential.
    ///
    /// The service is derived from this bundle's identifier, so a Debug build with its own
    /// identifier cannot reach the installed app's items — and neither can this delete.
    /// `errSecItemNotFound` means there was nothing to remove, which is a success.
    public func deleteAllOwnedItems() throws {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw mappedError(status)
        }
    }

    /// The name of every item this app owns. Names only — never the data behind them.
    ///
    /// **Adding `kSecReturnData` here does not work, and the way it fails is worth knowing.**
    /// A caller that wants every credential's bytes cannot get them in one call: on the macOS
    /// file-based keychain, `kSecReturnData` together with `kSecMatchLimitAll` returns
    /// `errSecParam` (-50) and no items at all. MEASURED on this Mac, macOS 26, against two
    /// items in one service. So reading everything is this call followed by one `read(_:)` per
    /// name, which is what `QotaFolioTokenVault.endEveryGrant()` does — and why nothing that
    /// has to be complete is allowed to depend on it.
    public func enumerateReferences() throws -> Set<CredentialReference> {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecItemNotFound:
            return []
        case errSecSuccess:
            break
        default:
            throw mappedError(status)
        }

        let attributes: [[String: Any]]
        if let values = result as? [[String: Any]] {
            attributes = values
        } else if let value = result as? [String: Any] {
            attributes = [value]
        } else {
            throw KeychainError.malformedResult
        }

        var references = Set<CredentialReference>()
        references.reserveCapacity(attributes.count)
        for item in attributes {
            guard let account = item[kSecAttrAccount as String] as? String else {
                throw KeychainError.malformedResult
            }
            references.insert(CredentialReference(rawValue: account))
        }
        return references
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func exactQuery(_ reference: CredentialReference) -> [String: Any] {
        var query = baseQuery()
        query[kSecAttrAccount as String] = reference.rawValue
        return query
    }

    private func mappedError(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecInteractionNotAllowed,
             errSecAuthFailed,
             errSecMissingEntitlement,
             errSecNotAvailable:
            .unavailable
        default:
            .unexpected(status)
        }
    }
}
