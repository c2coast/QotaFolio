import Foundation
import QotaFolioCore

nonisolated struct StoredTokenEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let revision: CredentialRevision
    let receivedAt: Date
    let provider: AccountProvider
    let payload: Payload

    // This is the one type in the app that holds BOTH halves of a credential. SecretString keeps the raw String out of
    // the type's storage, so interpolation, String(describing:), String(reflecting:), Mirror and dump() are covered at
    // once and no future author has to remember three conformances. The wire format is untouched: SecretString encodes
    // through a single value container, so each field is a bare plist string under the same coding key.
    enum Payload: Equatable, Sendable {
        case anthropic(accessToken: SecretString, refreshToken: SecretString, expiresAt: Date)
        case openai(
            accessToken: SecretString,
            refreshToken: SecretString,
            chatGPTAccountID: SecretString,
            accessExpiresAt: Date?
        )
    }

    init(
        revision: CredentialRevision,
        receivedAt: Date,
        provider: AccountProvider,
        payload: Payload
    ) {
        schemaVersion = Self.schemaVersion
        self.revision = revision
        self.receivedAt = receivedAt
        self.provider = provider
        self.payload = payload
    }
}

extension StoredTokenEnvelope {
    private enum PayloadType: String, Codable {
        case anthropic
        case openai
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case revision
        case receivedAt
        case provider
        case payloadType
        case accessToken
        case refreshToken
        case expiresAt
        case chatGPTAccountID
        case accessExpiresAt
    }

    nonisolated init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decode(UInt16.self, forKey: .schemaVersion)
        guard decodedSchemaVersion == Self.schemaVersion else {
            throw EnvelopeError.unknownSchema(decodedSchemaVersion)
        }

        let revision = try values.decode(CredentialRevision.self, forKey: .revision)
        let receivedAt = try values.decode(Date.self, forKey: .receivedAt)
        let provider = try values.decode(AccountProvider.self, forKey: .provider)
        let payloadType = try values.decode(PayloadType.self, forKey: .payloadType)
        let accessToken = try values.decode(SecretString.self, forKey: .accessToken)
        let refreshToken = try values.decode(SecretString.self, forKey: .refreshToken)

        guard !accessToken.isEmpty,
              !refreshToken.isEmpty,
              receivedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw EnvelopeError.malformed
        }

        let payload: Payload
        switch payloadType {
        case .anthropic:
            guard provider == .anthropic else {
                throw EnvelopeError.providerPayloadMismatch
            }
            let expiresAt = try values.decode(Date.self, forKey: .expiresAt)
            guard expiresAt.timeIntervalSinceReferenceDate.isFinite else {
                throw EnvelopeError.malformed
            }
            payload = .anthropic(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt
            )
        case .openai:
            guard provider == .openai else {
                throw EnvelopeError.providerPayloadMismatch
            }
            let accountID = try values.decode(SecretString.self, forKey: .chatGPTAccountID)
            let accessExpiresAt = try values.decodeIfPresent(Date.self, forKey: .accessExpiresAt)
            guard !accountID.isEmpty,
                  accessExpiresAt?.timeIntervalSinceReferenceDate.isFinite != false else {
                throw EnvelopeError.malformed
            }
            payload = .openai(
                accessToken: accessToken,
                refreshToken: refreshToken,
                chatGPTAccountID: accountID,
                accessExpiresAt: accessExpiresAt
            )
        }

        self.schemaVersion = decodedSchemaVersion
        self.revision = revision
        self.receivedAt = receivedAt
        self.provider = provider
        self.payload = payload
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(revision, forKey: .revision)
        try values.encode(receivedAt, forKey: .receivedAt)
        try values.encode(provider, forKey: .provider)

        switch payload {
        case .anthropic(let accessToken, let refreshToken, let expiresAt):
            try values.encode(PayloadType.anthropic, forKey: .payloadType)
            try values.encode(accessToken, forKey: .accessToken)
            try values.encode(refreshToken, forKey: .refreshToken)
            try values.encode(expiresAt, forKey: .expiresAt)
        case .openai(
            let accessToken,
            let refreshToken,
            let chatGPTAccountID,
            let accessExpiresAt
        ):
            try values.encode(PayloadType.openai, forKey: .payloadType)
            try values.encode(accessToken, forKey: .accessToken)
            try values.encode(refreshToken, forKey: .refreshToken)
            try values.encode(chatGPTAccountID, forKey: .chatGPTAccountID)
            try values.encodeIfPresent(accessExpiresAt, forKey: .accessExpiresAt)
        }
    }
}

nonisolated enum StoredTokenCoder {
    static func encode(_ envelope: StoredTokenEnvelope) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> StoredTokenEnvelope {
        try PropertyListDecoder().decode(StoredTokenEnvelope.self, from: data)
    }
}

nonisolated enum EnvelopeError: Error, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case unknownSchema(UInt16)
    case malformed
    case providerPayloadMismatch

    var description: String {
        switch self {
        case .unknownSchema:
            "credential envelope schema is unsupported"
        case .malformed:
            "credential envelope is malformed"
        case .providerPayloadMismatch:
            "credential envelope provider does not match its payload"
        }
    }

    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: []) }
}
