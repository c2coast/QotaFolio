import AppKit

/// Whether macOS actually put the status item on the menu bar.
///
/// On macOS 26 a third-party status item is not a window the app owns. The app registers it
/// with Control Center over XPC and Control Center decides whether to host it; the gate the
/// user sees is System Settings → Menu Bar → "Allow in the Menu Bar". A refused item is not
/// reported as refused: the app is handed a proxy window with a nonsense frame and told
/// nothing. This is how the app tells.
public nonisolated enum MenuBarPlacement: Hashable, Sendable {
    /// macOS has not answered yet. There is no window, or there is one it has not sized.
    case pending
    /// On the bar, where the user can see it.
    case placed
    /// Refused. The item exists, the app draws into it, and nobody can see it.
    case hiddenByMenuBarSettings
}

/// Reads the placement off a status-item button's window.
///
/// Measured on this Mac, macOS 26.6: the window first appears at origin (0, 0) with a height
/// of 0 — created but not yet placed — and settles at the top of the screen at height 30,
/// matching the bar's own thickness. Another Mac measured a refused item at origin (0, −17)
/// with height 22 instead of 33. So an unsized window is an unanswered question, and the two refusal
/// signals are taken independently: a window that starts below the bottom of the screen
/// space, or one no taller than the refused proxy, is not on any menu bar. A refusal macOS
/// one day hands back at a sane origin is still caught by its height, and the reverse.
public nonisolated func menuBarPlacement(ofStatusItemWindowFrame frame: CGRect?) -> MenuBarPlacement {
    guard let frame, frame.height > 0, frame.width > 0 else { return .pending }
    let looksLikeTheRejectedProxy = frame.origin.y < 0 || frame.height <= rejectedStatusItemProxyHeight
    return looksLikeTheRejectedProxy ? .hiddenByMenuBarSettings : .placed
}

/// The height of the proxy window macOS hands an app whose status item Control Center
/// refused: 22 pt, where an accepted item's window is 30 on this Mac and 33 on another.
public nonisolated let rejectedStatusItemProxyHeight: CGFloat = 22
