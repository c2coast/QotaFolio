import Foundation

/// Which quantity the menu-bar batteries are drawn to.
///
/// A battery shows one length. What the week still holds is what a person budgets across the
/// days, and every account has a week. What a five-hour session still holds is what can be spent
/// in the next minute, and only some accounts have one. So the week is the default, and the
/// session is a choice: an account with an open session then draws the session, and an account
/// with none draws its week.
///
/// The choice is a drawing choice and nothing else. The tooltip, what VoiceOver reads and the
/// panel's cards are unchanged by it.
public nonisolated enum StripShows: String, CaseIterable, Sendable {
    /// This five-hour session's own remaining share, for an account that has one.
    case session
    /// The week's own remaining share.
    case week

    /// The default, written here and nowhere else.
    public static let standard: StripShows = .week
}
