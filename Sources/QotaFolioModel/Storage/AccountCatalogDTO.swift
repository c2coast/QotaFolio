import Foundation

public nonisolated struct AccountRecord: Codable, Equatable, Sendable {
    public nonisolated enum AuthorizationStatus: String, Codable, Equatable, Sendable {
        case connected
        case needsReauthentication
    }

    public let id: AccountID
    public let name: String
    public let provider: AccountProvider
    public let credentialReference: CredentialReference
    public let displayOrder: Int
    public let status: AuthorizationStatus
    public let failedRevision: CredentialRevision?
    /// Which provider account this row's grant belongs to, once the provider has been asked.
    public let providerIdentity: ProviderAccountIdentity?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case provider
        case credentialReference
        case displayOrder
        case status
        case failedRevision
        case providerIdentity
    }

    public init(config: AccountConfig) {
        id = config.id
        name = config.name
        provider = config.provider
        credentialReference = config.credentialReference
        displayOrder = config.displayOrder
        providerIdentity = config.providerIdentity

        switch config.authorizationState {
        case .connected:
            status = .connected
            failedRevision = nil
        case .needsReauthentication(let revision):
            status = .needsReauthentication
            failedRevision = revision
        }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(AccountID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        provider = try values.decode(AccountProvider.self, forKey: .provider)
        credentialReference = try values.decode(CredentialReference.self, forKey: .credentialReference)
        displayOrder = try values.decode(Int.self, forKey: .displayOrder)
        status = try values.decode(AuthorizationStatus.self, forKey: .status)
        failedRevision = try values.decodeIfPresent(CredentialRevision.self, forKey: .failedRevision)
        // Absent on every row written before this field existed, and absent on a new row until
        // its first profile fetch answers. Both are ordinary: the row loads, the account polls,
        // and the identity is filled in when the provider is next asked. Requiring it here
        // would sign the user out of every account they already have, for an upgrade
        // they asked for as an improvement.
        providerIdentity = try? values.decodeIfPresent(ProviderAccountIdentity.self, forKey: .providerIdentity)

        guard status == .needsReauthentication || failedRevision == nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .failedRevision,
                in: values,
                debugDescription: "Connected catalog records cannot carry a failed revision."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(provider, forKey: .provider)
        try values.encode(credentialReference, forKey: .credentialReference)
        try values.encode(displayOrder, forKey: .displayOrder)
        try values.encode(status, forKey: .status)
        try values.encodeIfPresent(failedRevision, forKey: .failedRevision)
        try values.encodeIfPresent(providerIdentity, forKey: .providerIdentity)
    }

    public func makeAccountConfig() -> AccountConfig {
        let authorizationState: AccountAuthorizationState = switch status {
        case .connected:
            .connected
        case .needsReauthentication:
            .needsReauthentication(failedRevision: failedRevision)
        }

        return AccountConfig(
            id: id,
            name: name,
            provider: provider,
            credentialReference: credentialReference,
            displayOrder: displayOrder,
            authorizationState: authorizationState,
            providerIdentity: providerIdentity
        )
    }
}

public nonisolated struct AccountCatalogEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let accounts: [AccountRecord]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case accounts
    }

    public init(schemaVersion: UInt16, accounts: [AccountRecord]) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
    }
}
