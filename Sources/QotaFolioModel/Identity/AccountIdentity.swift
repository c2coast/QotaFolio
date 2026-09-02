import Foundation

public nonisolated struct AccountID: RawRepresentable, Codable, Hashable, Sendable, Identifiable { public let rawValue: UUID; public var id: Self { self }; public init(rawValue: UUID) { self.rawValue = rawValue } }

public nonisolated struct CredentialRevision: RawRepresentable, Codable, Hashable, Sendable { public let rawValue: UUID; public init(rawValue: UUID) { self.rawValue = rawValue } }

public nonisolated enum AccountProvider: String, Codable, CaseIterable, Sendable { case anthropic, openai }

public nonisolated struct CredentialReference: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  // The ONLY product-source minting producer is `init(accountID:)` below.
  // Vault and catalog mint through it; two hand-rolled spellings (especially UUID case drift) would silently mis-drive the orphan sweep. Canonical form: "account/<UUID.uuidString>".
  // Why the other initialiser exists, since the declaration alone cannot say it: `init(rawValue:)`
  // above is there to witness RawRepresentable/Codable, and the one product-source call to
  // `CredentialReference(rawValue:)` is Keychain attribute rehydration during enumeration. Catalog decoding invokes the
  // standard-library witness for this type; `StoredTokenEnvelope` carries no credential-reference field. EVERY hand
  // construction in product code uses `init(accountID:)`, and a second spelling would not fail anything — it would
  // quietly point the orphan sweep at a reference the vault never wrote.
  public init(accountID: AccountID) { self.rawValue = "account/\(accountID.rawValue.uuidString)" } }

/// Which provider account a grant belongs to.
///
/// Two QotaFolio accounts could be one provider account and nothing in the app could tell.
/// The authorize page grants whichever account the browser is already signed in to, and the
/// token response says nothing about whose account it is — so "Work" and "Personal" would
/// show identical bars under two names and the app would never say a word. This is what the
/// app asks the provider so it can say so.
///
/// **An account may not have one.** A row written before this existed carries no identity,
/// and neither does a row whose first profile fetch has not happened yet. That is a normal
/// state: the account polls, shows its numbers and behaves in every way like any other. It
/// simply cannot take part in duplicate detection until the provider has been asked.
public nonisolated struct ProviderAccountIdentity: Codable, Equatable, Hashable, Sendable {
  /// The provider's own identifier for the account. Anthropic sends `account.uuid`;
  /// ChatGPT's is the `chatgpt_account_id` claim in the ID token.
  public let accountKey: String

  /// The organization the grant acts within, when the provider names one. Anthropic sends
  /// `organization.uuid`. One account can hold several organizations with separate quotas,
  /// so this is part of the identity and not decoration.
  public let organizationKey: String?

  /// The address the provider prints for the account. Shown to the user when a second grant
  /// turns out to be the first account again; never used to decide identity, because a
  /// person can change their email and still be the same account.
  public let emailAddress: String?

  public init(accountKey: String, organizationKey: String?, emailAddress: String?) {
    self.accountKey = accountKey
    self.organizationKey = organizationKey
    self.emailAddress = emailAddress
  }

  /// Whether two grants are the same account acting in the same place.
  ///
  /// The email is deliberately not part of this. A different organization on the same
  /// account is a different set of numbers, so it is a legitimate second row.
  public func isSameAccount(as other: ProviderAccountIdentity) -> Bool {
    accountKey == other.accountKey && organizationKey == other.organizationKey
  }
}

public nonisolated enum AccountAuthorizationState: Codable, Equatable, Sendable { case connected; case needsReauthentication(failedRevision: CredentialRevision?) }

public nonisolated struct AccountConfig: Codable, Equatable, Sendable, Identifiable {
  public let id: AccountID; public var name: String; public let provider: AccountProvider; public let credentialReference: CredentialReference; public var displayOrder: Int; public var authorizationState: AccountAuthorizationState
  /// Which provider account this grant belongs to, once the provider has been asked. `nil`
  /// until then, and on every row written before the app knew how to ask.
  public var providerIdentity: ProviderAccountIdentity?
  public init(id: AccountID, name: String, provider: AccountProvider, credentialReference: CredentialReference, displayOrder: Int, authorizationState: AccountAuthorizationState, providerIdentity: ProviderAccountIdentity? = nil) {
    self.id = id; self.name = name; self.provider = provider; self.credentialReference = credentialReference; self.displayOrder = displayOrder; self.authorizationState = authorizationState; self.providerIdentity = providerIdentity } }
