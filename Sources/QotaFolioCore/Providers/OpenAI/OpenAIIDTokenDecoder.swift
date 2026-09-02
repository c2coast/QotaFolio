import Foundation

private nonisolated struct OpenAIIDTokenClaimsDTO: Decodable, Sendable {
    let authorization: OpenAIIDTokenAuthorizationDTO?

    private enum CodingKeys: String, CodingKey {
        case authorization = "https://api.openai.com/auth"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authorization = try? container.decode(OpenAIIDTokenAuthorizationDTO.self, forKey: .authorization)
    }
}

private nonisolated struct OpenAIIDTokenAuthorizationDTO: Decodable, Sendable {
    let accountID: SecretString?

    private enum CodingKeys: String, CodingKey {
        case accountID = "chatgpt_account_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try? container.decode(SecretString.self, forKey: .accountID)
    }
}

private nonisolated struct OpenAIAccessTokenClaimsDTO: Decodable, Sendable {
    let expiration: Double?

    private enum CodingKeys: String, CodingKey {
        case expiration = "exp"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expiration = try? container.decode(Double.self, forKey: .expiration)
    }
}

public nonisolated enum OpenAIIDTokenDecoder {
    // These take the credential itself, so they take the carrier. The raw JWT exists only inside
    // `payloadData`'s unwrap, never in a caller's local — which is where an interpolation would find it.
    public static func accountID(_ jwt: SecretString) -> SecretString? {
        guard let payload = payloadData(jwt) else { return nil }
        guard let claims = try? JSONDecoder().decode(OpenAIIDTokenClaimsDTO.self, from: payload) else {
            return nil
        }
        guard let accountID = claims.authorization?.accountID, !accountID.isEmpty else {
            return nil
        }
        return accountID
    }

    public static func accessExpiry(_ accessToken: SecretString) -> Date? {
        guard let payload = payloadData(accessToken) else { return nil }
        guard let claims = try? JSONDecoder().decode(OpenAIAccessTokenClaimsDTO.self, from: payload) else {
            return nil
        }
        guard let expiration = claims.expiration, expiration.isFinite, expiration > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: expiration)
    }

    private static func payloadData(_ jwt: SecretString) -> Data? {
        var payload: Data?
        jwt.withUnsafeRawValue { payload = payloadData(rawJWT: $0) }
        return payload
    }

    private static func payloadData(rawJWT jwt: String) -> Data? {
        guard !jwt.isEmpty, jwt.utf8.count <= CREDENTIAL_POST_MAX_BYTES else { return nil }

        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3, segments.allSatisfy({ !$0.isEmpty }) else { return nil }

        let payloadSegment = String(segments[1])
        guard payloadSegment.utf8.count <= CREDENTIAL_POST_MAX_BYTES else { return nil }
        guard let payload = Base64URL.decode(payloadSegment) else { return nil }
        guard payload.count <= CREDENTIAL_POST_MAX_BYTES else { return nil }
        return payload
    }
}
