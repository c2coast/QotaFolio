import QotaFolioCore

/// Which of the panel's seven bodies is on screen.
///
/// One rule decides it: **a failure to read is never rendered as an empty or reassuring state.**
/// "We could not read your accounts" and "you have no accounts" are different sentences, and only
/// one of them can be true at a time. Deciding it here makes that rule a value a test can read, in
/// the same way `AccountFace` already decides the card.
public nonisolated enum PanelBody: Equatable, Sendable {
    /// The recovery takeover. The account rows stay hidden behind it, whatever `accounts` holds.
    case catalogUnavailable
    case addFlow
    case loading
    /// The catalog answered and there really are no accounts.
    case noAccounts
    /// A rename or a removal is waiting for an answer about one account.
    ///
    /// It is a body, not an overlay, for the same reason `addFlow` is one: the panel opens no
    /// second window, so a question that needs an answer has to be the thing the panel shows.
    /// While it is on screen no other control of the panel is reachable, which is why a prompt and
    /// an add flow cannot both be live.
    case accountPrompt
    /// The catalog answered, accounts exist, and every one of them is hidden.
    case noVisibleAccounts
    case accounts
}

/// The body the panel shows, for one catalog state, one flow and one prompt.
///
/// The prompt sits below `noAccounts` in the order deliberately. A question about one account,
/// asked of a list that turns out to hold none, is a question about nothing — so an empty list
/// outranks it and the prompt disappears with the row it was about.
public nonisolated func panelBody(
    loadState: CatalogLoadState,
    hasRenderableFlow: Bool,
    hasAccountPrompt: Bool,
    accountCount: Int,
    visibleAccountCount: Int
) -> PanelBody {
    switch loadState {
    case .unreadable:
        // The row count is deliberately not consulted. A catalog that could not be read holds no
        // rows worth counting, and an empty list drawn here would be the app asserting the one
        // thing a failed read cannot assert.
        return hasRenderableFlow ? .addFlow : .catalogUnavailable
    case .loading:
        return hasRenderableFlow ? .addFlow : .loading
    case .missing, .loaded:
        if hasRenderableFlow { return .addFlow }
        if accountCount == 0 { return .noAccounts }
        if hasAccountPrompt { return .accountPrompt }
        return visibleAccountCount == 0 ? .noVisibleAccounts : .accounts
    }
}
