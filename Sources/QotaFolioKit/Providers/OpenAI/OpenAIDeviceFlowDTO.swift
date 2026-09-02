import Foundation
import QotaFolioCore

/// `POST /api/accounts/deviceauth/usercode`, decoded for what the server actually sends.
///
/// Verified against the live endpoint on 2026-08-27, twice. The shape it returned, written the
/// only way a captured wire example may be written here — **field names and types, never
/// values**:
///
/// ```
/// HTTP 200 · {"device_auth_id": string,
///              "user_code":     string,
///              "interval":      string holding a number,
///              "expires_at":    ISO 8601 with six fractional digits and a UTC offset}
/// ```
///
/// The rule is not decoration. Three of the four fields above are credential material or
/// credential-adjacent, a comment survives in git history after any deletion, and sorting live
/// fields into safe and unsafe by hand is exactly the judgement that gets one wrong. A type
/// tells the next reader everything the value would have, and the parser tests carry the
/// examples, built from synthetic values.
///
/// `interval` is a **string**. Both shapes are accepted; this endpoint is as undocumented as the
/// two usage endpoints and its types are nobody's promise.
nonisolated struct OpenAIDeviceUsercodeDTO: Decodable, Sendable {
    let deviceAuthID: SecretString?
    // `userCode` is the ONE credential-adjacent value the product shows on purpose — see the
    // rendering rule on AccountFlowPhase. It stays a plain String deliberately, and the redaction
    // suites hold it out of their secret list for that reason.
    let userCode: String?
    let interval: Double?
    /// When the server says this code stops working.
    let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case deviceAuthID = "device_auth_id"
        case userCode = "user_code"
        case interval
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceAuthID = try? container.decode(SecretString.self, forKey: .deviceAuthID)
        userCode = WireValue.string(.userCode, from: container)
        interval = WireValue.double(.interval, from: container)
        expiresAt = WireValue.string(.expiresAt, from: container).flatMap(WireValue.date(fromISO8601:))
    }
}

// This struct holds a COMPLETE OpenAI grant — the authorization code,
// the PKCE challenge and the PKCE verifier together. All three are the carrier type.
//
// Nobody has yet seen a successful poll response from this endpoint, so none of these three
// types is confirmed — and the one field on this flow that HAS been seen arrived as a string
// where a number was expected. A quoted value is therefore accepted for each of them, in the
// same spirit and for the same reason. What is confirmed against the live server is the
// unapproved case: HTTP 403 with `error.code = deviceauth_authorization_pending`, which the
// client's `case 403, 404: return .pending` already reads correctly.
//
// WHOEVER SEES THE FIRST 200 FROM THIS ENDPOINT: record the shape, never the body. This is the
// one response in the whole app that carries a complete grant — `authorization_code`,
// `code_challenge` and `code_verifier` in one object — and a body pasted here is a live grant
// committed to git history, where no later deletion reaches it. The shape, and all of it, is:
//
//     HTTP 200 · {"authorization_code": string, "code_challenge": string, "code_verifier": string}
//
// If a field arrives quoted where a number was expected, or arrives at all where it was not
// expected, say so in words on the line below this one. That sentence is what a reader needs;
// the value is what nobody needs.
nonisolated struct OpenAIDevicePollDTO: Decodable, Sendable {
    let authorizationCode: SecretString?
    let codeChallenge: SecretString?
    let codeVerifier: SecretString?

    private enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeChallenge = "code_challenge"
        case codeVerifier = "code_verifier"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authorizationCode = Self.secret(.authorizationCode, from: container)
        codeChallenge = Self.secret(.codeChallenge, from: container)
        codeVerifier = Self.secret(.codeVerifier, from: container)
    }

    /// A grant value, whether the server quoted it or not. The carrier type is built from
    /// the decoded text so the raw value never lands in a plain `String` on the way through.
    private static func secret(
        _ key: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> SecretString? {
        if let value = try? container.decode(SecretString.self, forKey: key) {
            return value
        }
        guard
            container.contains(key),
            (try? container.decodeNil(forKey: key)) != true,
            let number = try? container.decode(Double.self, forKey: key),
            number == number.rounded()
        else {
            return nil
        }
        return SecretString(String(Int64(number)))
    }
}
