import Foundation

/// Reads `GET /api/oauth/profile`, which is the only way to learn whose account a grant is.
///
/// ```
/// { "account": { "uuid": "…", "email_address": "…" }, "organization": { "uuid": "…" } }
/// ```
///
/// The email is spelled three ways by different clients — `email_address`, `emailAddress`,
/// `email` — and at either nesting level, so all of them are read. The email is a label; the
/// account UUID is the identity, and a response without one tells the app nothing it can
/// use.
public nonisolated enum AnthropicProfileParser {
  public static func parse(_ body: Data) throws -> ProviderAccountIdentity {
    guard body.count <= AnthropicWire.profileMaxResponseBytes else {
      throw UsageProviderError.invalidPayload
    }

    let dto: AnthropicProfileDTO
    do {
      dto = try JSONDecoder().decode(AnthropicProfileDTO.self, from: body)
    } catch {
      throw UsageProviderError.invalidPayload
    }

    guard let accountKey = nonEmpty(dto.accountUUID) else {
      throw UsageProviderError.invalidPayload
    }

    return ProviderAccountIdentity(
      accountKey: accountKey,
      organizationKey: nonEmpty(dto.organizationUUID),
      emailAddress: nonEmpty(dto.emailAddress)
    )
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }
}

nonisolated struct AnthropicProfileDTO: Decodable, Sendable {
  let accountUUID: String?
  let organizationUUID: String?
  let emailAddress: String?

  private enum CodingKeys: String, CodingKey {
    case account
    case organization
    case emailAddress = "email_address"
    case emailAddressCamel = "emailAddress"
    case email
  }

  private enum NestedKeys: String, CodingKey {
    case uuid
    case id
    case emailAddress = "email_address"
    case emailAddressCamel = "emailAddress"
    case email
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let account = try? container.nestedContainer(keyedBy: NestedKeys.self, forKey: .account)
    let organization = try? container.nestedContainer(keyedBy: NestedKeys.self, forKey: .organization)

    accountUUID = Self.first(of: [.uuid, .id], in: account)
    organizationUUID = Self.first(of: [.uuid, .id], in: organization)
    emailAddress = Self.first(of: [.emailAddress, .emailAddressCamel, .email], in: account)
      ?? Self.firstTopLevel(of: [.emailAddress, .emailAddressCamel, .email], in: container)
  }

  private static func first(
    of keys: [NestedKeys],
    in container: KeyedDecodingContainer<NestedKeys>?
  ) -> String? {
    guard let container else { return nil }
    for key in keys {
      if let value = WireValue.string(key, from: container) { return value }
    }
    return nil
  }

  private static func firstTopLevel(
    of keys: [CodingKeys],
    in container: KeyedDecodingContainer<CodingKeys>
  ) -> String? {
    for key in keys {
      if let value = WireValue.string(key, from: container) { return value }
    }
    return nil
  }
}
