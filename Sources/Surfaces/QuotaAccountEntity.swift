import AppIntents
import Foundation
import QotaFolioModel

/// One of the person's accounts, as Spotlight, Shortcuts and the Control's picker know it.
///
/// Compiled into the app and into the widget extension: each process resolves its own copy from
/// the same catalog file, so a Control configured in one is the account the other opens.
/// Deliberately not the catalog row itself — the row carries a credential reference, and this
/// carries a name.
nonisolated struct QuotaAccountEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "QotaFolio Account")
    static let defaultQuery = QuotaAccountQuery()

    let id: AccountID
    let name: String
    let provider: AccountProvider

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(providerDisplayName(provider))"
        )
    }

    init(id: AccountID, name: String, provider: AccountProvider) {
        self.id = id
        self.name = name
        self.provider = provider
    }

    init(_ account: SurfaceAccount) {
        self.init(id: account.id, name: account.name, provider: account.provider)
    }
}

// `nonisolated`, spelled out: this file is also compiled into the app, whose default actor is
// the main actor, and a main-actor-isolated conformance cannot witness a Sendable ID.
nonisolated extension AccountID: @retroactive EntityIdentifierConvertible {
    public var entityIdentifierString: String { rawValue.uuidString }

    public static func entityIdentifier(for entityIdentifierString: String) -> AccountID? {
        UUID(uuidString: entityIdentifierString).map(AccountID.init(rawValue:))
    }
}

/// The accounts, from the catalog file, in the person's order. Five at most, so every query
/// answers with all of them.
nonisolated struct QuotaAccountQuery: EntityQuery, EntityStringQuery, Sendable {
    func entities(for identifiers: [AccountID]) async throws -> [QuotaAccountEntity] {
        let wanted = Set(identifiers)
        return allAccounts().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [QuotaAccountEntity] {
        allAccounts()
    }

    func entities(matching string: String) async throws -> [QuotaAccountEntity] {
        allAccounts().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    private func allAccounts() -> [QuotaAccountEntity] {
        guard case .reading(let reading) = SurfaceReading.read() else { return [] }
        return reading.accounts.map(QuotaAccountEntity.init)
    }
}

/// The product each provider's account is for, as a person says it.
nonisolated func providerDisplayName(_ provider: AccountProvider) -> String {
    switch provider {
    case .anthropic: String(localized: "Claude", comment: "The product an Anthropic account is for.")
    case .openai: String(localized: "ChatGPT", comment: "The product an OpenAI account is for.")
    }
}
