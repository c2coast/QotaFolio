import SwiftUI

@MainActor public enum AccessibilityAnnouncer {
    public static func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    public static func layoutChanged() {
        AccessibilityNotification.LayoutChanged().post()
    }

    public static func screenChanged() {
        AccessibilityNotification.ScreenChanged().post()
    }
}
