import Foundation

/// Which quantity the menu-bar batteries are drawn to.
///
/// A battery shows one length, and there are two worth showing. What this five-hour session
/// still holds is what you can act on in the next minute. What the week still holds is what you
/// are budgeting across the days. Both are true of the same account at the same instant, each on
/// its own budget, and which one belongs on the bar depends on how a person works — so it is
/// theirs to choose.
///
/// The choice is a drawing choice and nothing else. The words say both figures in both modes:
/// the tooltip, what VoiceOver reads, the Control's title and the panel's cards are unchanged by
/// it. So the strip is never the whole answer on its own, in either mode.
public nonisolated enum StripShows: String, CaseIterable, Sendable {
    /// This five-hour session's own remaining share. The default, because a battery is read to
    /// know whether to start something.
    case session
    /// The week's own remaining share.
    case week
}

/// The length one battery is drawn to, once the choice is made.
///
/// The two modes are mirror images: each draws one fill, of its own quantity, in the colour of
/// its own quantity, and nothing stands behind it. A second length behind the first is
/// invisible whenever the drawn window is the healthier of the two, and
/// when it is not, a long pale bar behind a short bright one says "plenty" and "nearly out" in
/// the same glance. Apple's battery language then applies to whatever is drawn: the palette
/// takes it red at a fifth or less, and nothing at all is the residual hairline.
///
/// This lives in the model rather than in the renderer because two processes draw from it: the
/// app's own strip, and the Control in the widget extension, which links this target and not the
/// app's. One rule, one file, both pictures.
public nonisolated struct StripFigure: Hashable, Sendable {
    /// The share still held of the quantity that was asked for, 0…100. The battery's length, and
    /// the number its colour is chosen from.
    public let remainingPercent: Int
    /// Nothing of it left: Apple's residual hairline at the leading edge.
    public let isSpent: Bool

    public init(showing: StripShows, weeklyRemainingPercent: Int, sessionRemainingPercent: Int) {
        remainingPercent = switch showing {
        case .session: sessionRemainingPercent
        case .week: weeklyRemainingPercent
        }
        isSpent = remainingPercent <= 0
    }

    /// The length as a share of the fill box.
    public var fraction: Double { Double(remainingPercent) / 100 }
}
