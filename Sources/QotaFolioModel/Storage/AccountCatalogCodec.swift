import Foundation

/// Why a catalog could not be read, when the read never happened.
///
/// Every case here is a statement about the machine or the location, never about the
/// catalog's contents. That is the whole point of the type: it is what a reader may
/// say when it learned nothing about the bytes.
public nonisolated enum CatalogReadObstruction: Equatable, Sendable {
    /// A resource the read needs was not available: descriptors (`EMFILE`/`ENFILE`),
    /// memory (`ENOMEM`), or a device that answered with a transient error. The same
    /// read, attempted later, can succeed.
    case resourcesUnavailable

    /// The directory the catalog must live in is not one this build may use: the wrong
    /// mode, the wrong owner, a symlink on the path, an absent anchor, or an anchor
    /// outside the container the uninstall manifest declares. An environment fault,
    /// reported as itself — the catalog file is not even examined, and nothing about it
    /// is claimed.
    case anchorUnusable
}

/// What one attempt to read the durable catalog learned.
///
/// The type carries four outcomes because the reader computes four, and the distinction
/// between them decides what the app does next and what the user is told:
///
/// - `.missing`   — proven absent by descriptor-anchored, no-follow inspection. Normal on
///                  a first launch. The empty account list IS the truth here.
/// - `.loaded`    — the rows.
/// - `.corrupt`   — the bytes were read and they are not a catalog this build can trust.
///                  DURABLE: reading the same bytes again produces the same verdict, so
///                  quarantine is right and the user must be told their catalog is broken.
/// - `.temporarilyUnreadable` — the read did not happen. NOTHING is known about the bytes,
///                  so nothing about them may be reported and no recovery may be performed
///                  on them. Retrying is meaningful, and the app must offer a way back.
///
/// `.corrupt` and `.temporarilyUnreadable` are separate cases, because one case for both
/// makes a momentary descriptor exhaustion indistinguishable from a tampered file: both would
/// hide every account row and freeze durable mutation for the rest of the process. This is the
/// same false collapse `StoredCredentialScan` refuses (see `TokenVault.swift`): **a failure to
/// READ is not the fact that the data is BAD.** The refusal is enforced by the compiler rather
/// than by discipline:
///
/// - `store.load() ?? []` does not compile — there is no optional to collapse.
/// - `.temporarilyUnreadable` cannot be spelled without naming the obstruction observed,
///   so no caller can claim "transient" without saying what it saw.
/// - `.corrupt` carries no obstruction, so a durable verdict cannot be laundered into a
///   retryable one by passing its payload along; there is none to pass.
/// - Every consumer that ignores a case fails exhaustiveness.
///
/// There is deliberately no `classify(readFailure:)` here. An errno alone proves neither
/// verdict — a dangling symlink and an absent leaf can both surface as `ENOENT` — so only
/// the descriptor-anchored, no-follow inspection in `CatalogFileIO` may decide, and a
/// helper whose only honest answer is "I do not know" is an invitation to the collapse
/// this type exists to prevent.
public nonisolated enum CatalogLoadResult: Equatable, Sendable {
    case missing
    case loaded([AccountRecord])
    case corrupt
    case temporarilyUnreadable(CatalogReadObstruction)
}

public nonisolated enum CatalogPersistenceError: Error, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case encoding(any Error)
    case write(any Error)

    public var description: String {
        switch self {
        case .encoding:
            "catalog encoding failed"
        case .write:
            "catalog write failed"
        }
    }

    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

public nonisolated enum AccountCatalogCodec {
    public static let schemaVersion: UInt16 = 1

    /// The largest catalog this product can author, with headroom, measured by running the
    /// shipping encoder over the worst case:
    ///
    ///   envelope with zero accounts .................................       33 bytes
    ///   five accounts, empty names, widest `displayOrder` (Int.min),
    ///   every optional present (`needsReauthentication` + failedRevision)  1 532 bytes
    ///
    /// Five accounts is the product cap: `AccountCatalog.reserveAddSlot` refuses a
    /// sixth and `AccountCatalogCodec.decode` refuses to load one. Every other
    /// field is fixed width. The account name is the one unbounded field, so the
    /// bound is the name budget:
    ///
    ///   allowance ...................... 4 096 characters per name, 16x a macOS
    ///                                    filename, far past anything a person types
    ///   worst-case JSON expansion ...... 6 bytes out per 1 byte in (a control
    ///                                    character escapes to `\uXXXX`; measured
    ///                                    against astral scalars, which cost 4)
    ///   5 x 4 096 x 6 .................. 122 880 bytes
    ///   plus the fixed structure ....... 124 412 bytes
    ///
    /// 128 KiB is the next power of two above that, so the pathological legal
    /// maximum still fits. A real five-account catalog measures 1 077 bytes, which
    /// leaves 121x headroom over anything the product actually writes. Anything
    /// larger is not a catalog: it is refused as `.corrupt` before a byte of it is
    /// allocated. The writer applies the same bound, so the store never authors
    /// bytes this reader would refuse.
    public static let maximumBytes = 128 * 1024

    public static func encode(_ records: [AccountRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            AccountCatalogEnvelope(schemaVersion: schemaVersion, accounts: records)
        )
    }

    /// Every verdict this function can reach is DURABLE. It is only ever handed bytes that
    /// were read in full, so a refusal here is a statement about those bytes: they are not
    /// a catalog this build can trust, and reading them again cannot change that. It never
    /// answers `.temporarilyUnreadable`, because a decoder never learns anything about the
    /// machine — and it never answers `.missing` for empty bytes, because an absent leaf is
    /// proven by descriptor-anchored inspection, not by a decode failure.
    public static func decode(_ data: Data?) -> CatalogLoadResult {
        guard let data else { return .missing }

        do {
            let envelope = try JSONDecoder().decode(AccountCatalogEnvelope.self, from: data)
            guard envelope.schemaVersion == schemaVersion,
                  envelope.accounts.count <= 5,
                  structuralInvariantsHold(for: envelope.accounts) else {
                return .corrupt
            }
            return .loaded(envelope.accounts)
        } catch {
            return .corrupt
        }
    }

    private static func structuralInvariantsHold(for records: [AccountRecord]) -> Bool {
        var ids = Set<AccountID>()
        var references = Set<CredentialReference>()

        for record in records {
            guard ids.insert(record.id).inserted,
                  references.insert(record.credentialReference).inserted,
                  record.credentialReference == CredentialReference(accountID: record.id) else {
                return false
            }
        }
        return true
    }
}
