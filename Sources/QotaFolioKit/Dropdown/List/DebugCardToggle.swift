#if DEBUG
import Foundation

/// The lab's way of opening and closing a card after launch.
///
/// `QOTAFOLIO_UI_TOGGLE=<account name>@<ms>,<ms>,…` — the account, and the times from the moment
/// the panel opens at which its card is toggled. The open card is the list's own state, and this
/// Mac takes no synthetic clicks, so without this hook the one motion the panel runs cannot be
/// watched at all: `QOTAFOLIO_UI_EXPANDED` can only open a card before the panel is on screen.
/// A post here reaches `expanded` by the same path a tap does, so what is watched is the motion
/// the product runs.
public enum DebugCardToggle {
    public static let notification = Notification.Name("QotaFolio.debug.toggleCard")
    /// The account's name, under this key.
    public static let accountNameKey = "accountName"

    public static func post(accountNamed name: String) {
        NotificationCenter.default.post(
            name: notification,
            object: nil,
            userInfo: [accountNameKey: name]
        )
    }
}
#endif
