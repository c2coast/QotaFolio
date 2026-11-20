import Foundation

/// What the account will meet first this week, from the verdicts of its two limits: the account's
/// forecast. Each case is one thing a person can be told, and carries only what it says.
public enum AccountForecast: Hashable, Sendable {
    /// The week is at 100 percent. Nothing runs until it resets.
    case spent
    /// The model's week is at 100 percent and the week is not. Other models run on the week, and
    /// this is the week's verdict.
    case modelSpent(week: Verdict)
    /// Neither limit has been used this week.
    case notStarted
    /// Too early to say: the week is silent, and the model's week does not run out.
    case silent
    /// A limit runs out before the reset. `first` is the one that runs out first, and on a tie the
    /// week. `other` is the verdict of the other limit, absent for an account with only the week.
    case runsOut(first: Limit.Kind, at: Date, speed: Verdict.Speed, other: Verdict?)
    /// Neither limit runs out: the week lands at `landing`, and the model's week, when it lasts too,
    /// at `modelLanding`.
    case lasts(landing: Double, modelLanding: Double?, speed: Verdict.Speed)
}
