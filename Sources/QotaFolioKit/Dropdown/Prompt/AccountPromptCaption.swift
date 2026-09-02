import SwiftUI
import QotaFolioCore

/// The one caption slot a prompt reserves, whether or not it has anything to say.
///
/// A caption that appeared and disappeared as the user typed would move the buttons under it on
/// every keystroke, and grow and shrink the glass around them. The slot is therefore always
/// present and always the same height; only its text changes.
///
/// Three things can want the slot, and they are ranked by what the user most needs to know:
///
/// 1. the last press was refused, and this is why;
/// 2. the confirming button is dimmed, and this is why;
/// 3. the field's contents are not yet usable.
struct AccountPromptCaption: View {
    let refusalReason: String?
    let blockedReason: String?
    let validationReason: String?

    var body: some View {
        // A space, not an empty string: `Label` drops an empty title entirely, and a slot that
        // reserves two lines of nothing is the whole point of this view.
        Label(text ?? " ", systemImage: symbolName)
            .font(.caption)
            .foregroundStyle(foreground)
            .lineLimit(2, reservesSpace: true)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(text == nil ? 0 : 1)
            .accessibilityHidden(text == nil)
            .accessibilityIdentifier(AXIdentifiers.accountPromptCaption)
    }

    private var text: String? {
        refusalReason ?? blockedReason ?? validationReason
    }

    private var symbolName: String {
        if refusalReason != nil { return "exclamationmark.triangle.fill" }
        if blockedReason != nil { return "lock.fill" }
        return "pencil"
    }

    private var foreground: HierarchicalShapeStyle {
        refusalReason != nil ? .primary : .secondary
    }
}
