import Foundation

/// A fall inside one week: a banked reset gave points back between two polls.
///
/// A fall is told apart from the two meters together. One model-week point is half a weekly
/// point, so a reset of the model's week alone gives back half its reading to the week.
public struct Fall: Hashable, Sendable {
    public let kind: Kind
    /// The poll before the fall and the poll after it.
    public let before: Reading
    public let after: Reading
    /// Points given back, for the week and for the model's week.
    public let givenBack: [Limit.Kind: Double]

    public init(kind: Kind, before: Reading, after: Reading, givenBack: [Limit.Kind: Double]) {
        self.kind = kind
        self.before = before
        self.after = after
        self.givenBack = givenBack
    }

    /// The hours between the two polls. The fall happened somewhere inside them.
    public var hours: Double {
        (after.at.timeIntervalSince1970 - before.at.timeIntervalSince1970) / 3600.0
    }

    public enum Kind: Hashable, Sendable {
        /// The model's week alone reset: all of it came back, and half of it to the week.
        case model
        /// Everything reset: the week and the model's week both came back whole.
        case full
        /// The week fell and the two meters do not say why. What it lost is given back to the week.
        case unexplained
    }
}
