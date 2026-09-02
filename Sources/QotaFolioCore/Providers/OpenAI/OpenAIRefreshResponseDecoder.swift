import Foundation

public nonisolated struct OpenAIRefreshResponseDecoder: ProviderRefreshResponseDecoder {
    public let provider: AccountProvider = .openai

    public init() {}

    public func decodeRefreshResponse(status: Int, body: Data) throws -> OAuthTokenRefreshDelta {
        try Task.checkCancellation()
        guard body.count <= CREDENTIAL_POST_MAX_BYTES else {
            throw TokenRefreshError.transient
        }

        guard (200..<300).contains(status) else {
            let code = (try? JSONDecoder().decode(OpenAIOAuthErrorEnvelopeDTO.self, from: body))?.error
            switch code {
            case "invalid_grant":
                throw TokenRefreshError.permanent(.openAIInvalidGrant)
            case "refresh_token_expired":
                throw TokenRefreshError.permanent(.openAIRefreshTokenExpired)
            case "refresh_token_invalidated":
                throw TokenRefreshError.permanent(.openAIRefreshTokenInvalidated)
            case "refresh_token_reused":
                throw TokenRefreshError.permanent(.openAIRefreshTokenReused)
            default:
                throw TokenRefreshError.transient
            }
        }

        guard let dto = try? JSONDecoder().decode(OpenAITokenResponseDTO.self, from: body) else {
            throw TokenRefreshError.transient
        }
        guard case .value(let accessToken) = dto.accessToken, !accessToken.isEmpty else {
            throw TokenRefreshError.transient
        }

        let refreshToken: SecretString?
        switch dto.refreshToken {
        case .absentOrNull:
            refreshToken = nil
        case .value(let value) where !value.isEmpty:
            refreshToken = value
        case .value, .invalid:
            throw TokenRefreshError.transient
        }

        let accountID: SecretString?
        switch dto.idToken {
        case .absentOrNull:
            accountID = nil
        case .value(let idToken) where !idToken.isEmpty:
            guard let decoded = OpenAIIDTokenDecoder.accountID(idToken) else {
                throw TokenRefreshError.transient
            }
            accountID = decoded
        case .value, .invalid:
            throw TokenRefreshError.transient
        }

        return .openai(
            accessToken: accessToken,
            refreshToken: refreshToken,
            chatGPTAccountIDFromIDToken: accountID,
            accessExpiresAt: OpenAIIDTokenDecoder.accessExpiry(accessToken)
        )
    }
}
