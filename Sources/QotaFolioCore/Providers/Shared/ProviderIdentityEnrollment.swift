import Foundation

/// Answers the one question the add flow has to ask before it commits a grant: **is this
/// provider account already in the app?**
///
/// Called by the account lifecycle after a grant is minted and its profile fetched, and
/// before the row is written. A match is not an error the app recovers from — it is the
/// user having granted the same account twice, which the browser will do silently every
/// time it is already signed in.
public nonisolated enum ProviderIdentityEnrollment {
  /// The account this identity collides with, or `nil` when it is new.
  ///
  /// - Parameters:
  ///   - identity: the identity the provider reported for the grant just made.
  ///   - provider: which provider it came from. Identifiers are only unique within one
  ///     provider, so a match is never claimed across the two.
  ///   - accounts: the rows the app already holds.
  ///   - excluding: an account that may not collide with itself — the row being
  ///     reconnected, in the flow that mints a fresh grant for an account already present.
  /// - Returns: the colliding account, so the caller can name it. An account whose identity
  ///   is not yet known never collides: the app has not asked the provider about it, and
  ///   refusing on a guess would block a legitimate second account.
  public static func existingAccount(
    matching identity: ProviderAccountIdentity,
    provider: AccountProvider,
    in accounts: [AccountConfig],
    excluding excluded: AccountID? = nil
  ) -> AccountConfig? {
    accounts.first { account in
      guard account.provider == provider else { return false }
      guard account.id != excluded else { return false }
      guard let known = account.providerIdentity else { return false }
      return known.isSameAccount(as: identity)
    }
  }

  /// The accounts whose provider identity is still unknown, in display order.
  ///
  /// Every row written before the app learned to ask starts here. They work normally; they
  /// simply cannot take part in the check above until someone fetches their profile. This
  /// is the list to walk when doing that — after a successful poll, when the access token is
  /// known good and one extra GET costs nothing anyone will notice.
  public static func awaitingIdentity(in accounts: [AccountConfig]) -> [AccountConfig] {
    accounts
      .filter { $0.providerIdentity == nil }
      .sorted { $0.displayOrder < $1.displayOrder }
  }
}
