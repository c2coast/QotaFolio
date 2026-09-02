import Foundation

// This carries `id_token`, `access_token` and `refresh_token`
// off the wire. The payload is the carrier type, so no raw String ever reaches the field.
nonisolated enum OpenAIStringFieldDTO: Sendable {
    case absentOrNull
    case value(SecretString)
    case invalid
}

nonisolated struct OpenAITokenResponseDTO: Decodable, Sendable {
    let idToken: OpenAIStringFieldDTO
    let accessToken: OpenAIStringFieldDTO
    let refreshToken: OpenAIStringFieldDTO

    private enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        idToken = Self.decodeString(.idToken, from: container)
        accessToken = Self.decodeString(.accessToken, from: container)
        refreshToken = Self.decodeString(.refreshToken, from: container)
    }

    private static func decodeString(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> OpenAIStringFieldDTO {
        guard container.contains(key) else { return .absentOrNull }
        guard (try? container.decodeNil(forKey: key)) != true else { return .absentOrNull }
        guard let value = try? container.decode(SecretString.self, forKey: key) else { return .invalid }
        return .value(value)
    }
}

nonisolated struct OpenAIOAuthErrorEnvelopeDTO: Decodable, Sendable {
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try? container.decode(String.self, forKey: .error)
    }
}

public nonisolated enum OpenAILoginTokenDecoder {
    public static func decodeLoginTokens(body: Data) -> OAuthTokenSet? {
        guard body.count <= CREDENTIAL_POST_MAX_BYTES else { return nil }
        guard let dto = try? JSONDecoder().decode(OpenAITokenResponseDTO.self, from: body) else {
            return nil
        }
        guard
            case .value(let idToken) = dto.idToken,
            !idToken.isEmpty,
            case .value(let accessToken) = dto.accessToken,
            !accessToken.isEmpty,
            case .value(let refreshToken) = dto.refreshToken,
            !refreshToken.isEmpty,
            let accountID = OpenAIIDTokenDecoder.accountID(idToken)
        else {
            return nil
        }

        return .openai(
            accessToken: accessToken,
            refreshToken: refreshToken,
            chatGPTAccountID: accountID,
            accessExpiresAt: OpenAIIDTokenDecoder.accessExpiry(accessToken)
        )
    }
}
