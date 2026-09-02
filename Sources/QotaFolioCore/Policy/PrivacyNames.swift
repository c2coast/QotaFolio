import Foundation

/// The name a surface shows for an account while names are hidden.
///
/// One rule for the strip's tooltip and sentence, the card and its spoken sentence: while the
/// screen is shared, or while the person has asked for it, an account is called by its provider
/// and nothing else. The person's own name for it is theirs and stays off screen.
public nonisolated func presentedAccountName(_ account: AccountConfig, namesHidden: Bool) -> String {
    namesHidden ? hiddenAccountName(for: account.provider) : account.name
}

public nonisolated func hiddenAccountName(for provider: AccountProvider) -> String {
    switch provider {
    case .anthropic:
        qfLocalized("privacy.hiddenName.anthropic", defaultValue: "Anthropic account", comment: "Stands in for an Anthropic account's name while account names are hidden.")
    case .openai:
        qfLocalized("privacy.hiddenName.openai", defaultValue: "ChatGPT account", comment: "Stands in for a ChatGPT account's name while account names are hidden.")
    }
}
