import Foundation

/// What the forecast says about one limit at one moment. Each kind carries only what it can know,
/// so a spent limit has no rate and a silent one has no time.
public enum Verdict: Hashable, Sendable {
    /// The limit, or the account's week above it, is at 100 percent.
    case spent
    /// The forecast does not speak, and says why.
    case silent(Silence)
    /// At this rate the limit reaches 100 percent before it resets.
    case runsOut(at: Date, rate: Double, speed: Speed)
    /// At this rate the limit still has room at its reset. The landing is the percent used then.
    case lasts(landing: Double, rate: Double, speed: Speed)

    public enum Silence: Hashable, Sendable {
        /// Nothing is used yet.
        case notStarted
        /// The week has no clock to measure a rate on: no unblocked time has passed in it.
        case noClockYet
        /// One whole percent of the reading either way changes what the verdict would say.
        case insideOneStep
    }

    /// Which rate spoke. Rates are in points an hour.
    public enum Speed: Hashable, Sendable {
        /// The last three hours' work, while the meter moves.
        case burn
        /// The whole week's pace, when the last three hours are quiet.
        case weekPace
    }
}
