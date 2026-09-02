import Foundation

/// Every number that decides how much history QotaFolio keeps, and why each one is that
/// number rather than another.
///
/// ## What the samples are for
///
/// The only consumer is the verdict engine, `FleetBrain`. It asks three questions:
///
///  1. **Where does this window land?** A burn rate over the current occurrence, projected
///     to the reset instant.
///  2. **How many sessions are left in the week?** The median weekly cost of a completed
///     short window, over the last several of them, needing at least three.
///  3. **Am I early in the window?** The first 10–15% of an occurrence is damped, because a
///     post-reset burst read linearly looks like a deficit that is not there.
///
/// Question 1 wants a trace over hours. Question 3 wants the occurrence's start instant.
/// Question 2 wants **one number per completed occurrence** — not a trace at all.
///
/// ## Why this is not "15-minute samples for eight days"
///
/// Eight days of trace kept to answer question 2 would be trace nobody reads, because
/// question 2 does not read a trace. Over eight days a five-hour window closes about
/// thirty-eight times; thirty-eight numbers answer it exactly. Seven hundred and sixty-eight
/// samples per window answer it approximately, and cost twenty times the bytes.
///
/// Approximately, because a trace has gaps. The app polls between every three minutes and
/// every thirty (`AdaptiveCadence`), so the last sample before a reset can be half an hour
/// stale, and a window's true final consumption is then a guess. `CompletedUsageWindow`
/// records that number **at the poll where the reset is observed**, from the reading that
/// observed it — the best figure the app will ever hold for that occurrence. So the ledger
/// is not a cheaper answer to question 2. It is a better one.
///
/// The sampling serves questions 1 and 3: fine resolution over the recent past, coarse
/// resolution over the long past.
///
/// ## One minute is a floor the poller cannot beat
///
/// `PollingPolicy.hardFloor` is 180 seconds and the idle tiers run to 1,800. A "one-minute
/// sample" therefore never happens on its own; the minimum spacing below exists to stop a
/// user holding down Refresh from filling a ring in ten minutes, not to thin a stream that
/// arrives that fast. In ordinary use a 24-hour short-window ring holds roughly 100–150
/// samples, not 1,440.
public nonisolated enum UsageHistoryPolicy {
    // MARK: - Resolution

    /// A window this long or shorter gets fine-grained samples. Five hours at both providers
    /// today; the comparison is on the length so a provider that ships a two-hour limit is
    /// treated as the short window it is, without anybody editing an enum.
    public static let fineGrainedWindowCeiling: TimeInterval = 6 * 3_600

    /// Fine tier: one sample a minute at most, kept for a day.
    public static let fineSampleSpacing: TimeInterval = 60
    public static let fineSampleHorizon: TimeInterval = 26 * 3_600

    /// Coarse tier: one sample a quarter-hour at most, kept for eight days and a half.
    /// The half day is what makes a seven-day window's *previous* occurrence visible
    /// alongside the whole of the current one.
    public static let coarseSampleSpacing: TimeInterval = 15 * 60
    public static let coarseSampleHorizon: TimeInterval = 8.5 * 86_400

    // MARK: - Capacity

    /// The hard capacity of one ring, oldest evicted first.
    ///
    /// The horizons above are the ordinary bound and this is the backstop that makes the
    /// file's size arithmetic rather than a hope. At the coarse spacing 768 samples is
    /// exactly eight days, so the capacity and the horizon bind at the same moment. At the
    /// fine spacing it is 12.8 hours of held-down Refresh, or 38 hours of the fastest
    /// cadence the poller will ever choose on its own — either way past a day.
    public static let sampleCapacity = 768

    /// Completed occurrences kept per window. Eight days of five-hour windows is
    /// thirty-eight; the median in question 2 reads the recent ones and needs three.
    public static let completedWindowCapacity = 64

    /// Distinct windows kept per account, least-recently-seen evicted.
    ///
    /// The set of windows is not fixed and is not ours to predict: Anthropic names its
    /// model-scoped limits by display name and may add one on any deploy, and a rename is
    /// indistinguishable from an addition. Four is what the two providers report today.
    /// Eight is the point past which the app has stopped tracking limits and started
    /// accumulating names.
    public static let windowsPerAccount = 8

    /// An account with no successful poll for this long is dropped from the file.
    ///
    /// This is what makes removal self-healing without a call site: a removed account's
    /// history ages out on its own. `UsageHistory.forget(_:)` exists so it goes at once
    /// instead, which is what the Remove button should do.
    public static let accountHorizon: TimeInterval = coarseSampleHorizon

    // MARK: - Durability

    /// How long a sample may sit in memory before it is written.
    ///
    /// **The choice, and what it costs.** A sample every poll would mean a file write every
    /// poll: with four accounts at the three-minute floor, eighty writes an hour, for hours,
    /// on a battery. Writes are batched behind one deadline instead — roughly twelve an hour
    /// at the same poll rate, and none at all while nothing is polling, because the deadline
    /// is armed by the first unwritten sample and disarmed when it fires.
    ///
    /// It is a deadline and not a debounce on purpose. A debounce restarts on every sample,
    /// so a busy app never writes; a deadline bounds staleness at five minutes whatever
    /// arrives.
    ///
    /// **What a hard power-off costs.** Up to five minutes of samples, and up to five
    /// minutes of snapshot age. The snapshot is drawn with its own timestamp and the app
    /// refetches within three minutes of launch, so five minutes of extra age is invisible.
    /// Five minutes is 0.3% of a 24-hour trace and the projection is a slope over hours.
    /// A crash, a force-quit, a log-out and a restart all lose nothing at all: the page
    /// cache outlives the process, and only losing power loses the page cache.
    ///
    /// Against that: a stutter every minute for years. The trade is not close.
    public static let writeDeadline: Duration = .seconds(300)

    /// Ten percent of whatever deadline is in force, so the system folds this wake into one it
    /// was making anyway.
    ///
    /// A function and not a constant. A constant would be ten percent of the production
    /// deadline and nothing at all to do with the deadline a test injects, which is measured in
    /// milliseconds. This is the expression; there is no second copy of it to go stale.
    public static func writeDeadlineTolerance(for deadline: Duration) -> Duration {
        deadline / 10
    }

    /// How long the trace book may sit in memory unwritten.
    ///
    /// The two books have different readers and therefore different durability. The snapshot
    /// book fills the panel at the instant it opens, so it is written on every deadline that
    /// changed it — it is four kilobytes and nobody notices. The trace book is forty times
    /// larger, a real fleet measures 177 KB, and its only reader is the verdict engine, which
    /// calls `flush()` before it reads and therefore never reads the file at all. The file
    /// exists for one purpose: to survive a power cut.
    ///
    /// So the interval is derived from the coarsest thing the file records.
    /// `coarseSampleSpacing` is the longest gap between two samples the app will ever keep, so
    /// writing at least that often means a coarse ring is never more than one sample behind.
    /// Writing more often than that costs 177 KB a time and buys resolution the file does not
    /// have.
    ///
    /// **What it costs, exactly.** A quit keeps everything: `flushTraces` ignores this deadline
    /// and `AccountsStore.flushHistory()` calls it on the way out. An *ungraceful* exit — a
    /// crash, a force-quit, a power cut — costs up to fifteen minutes of trace.
    /// On a coarse ring that is at most one sample of eight days. On a fine
    /// ring it is up to fifteen samples of a twenty-six-hour ring, and the reader of that ring
    /// projects a slope over hours, which a quarter-hour gap does not bend. If the app then
    /// goes quiet — a dark machine stops every supervisor — the unwritten samples wait for the
    /// next poll or the quit rather than for a clock, because arming a timer to carry one
    /// sample across an overnight would spend exactly the wake this deadline exists to save.
    ///
    /// Against that: the trace file is written four times an hour instead of twelve, which is
    /// where two thirds of this subsystem's write volume went.
    public static let traceWriteDeadline: Duration = .seconds(Int(coarseSampleSpacing))

    // MARK: - What the poller does

    /// The closest together and the furthest apart `AdaptiveCadence` will ever place two
    /// requests, in seconds.
    ///
    /// Written here rather than read from `PollingPolicy`, because this target imports
    /// Foundation and nothing else — the brain and the ledger both move through it, and the
    /// poller does not. `BrainKnowsThePollerTests` pins both numbers to the poller's own.
    ///
    /// Three readers, each for its own reason. The ledger will not read a fall inside the
    /// first twentieth of an occurrence as its ending, and the floor is what makes that
    /// twentieth a real interval rather than two readings. The activity profile calls a gap
    /// unobserved when it is more than three times the cadence in force, and the cadence in
    /// force is never below the floor. And every forecast band is floored on one poll interval
    /// of burn, which is the ceiling.
    public static let pollFloorSeconds: Double = 180
    public static let pollCeilingSeconds: Double = 1_800

    // MARK: - Field bounds

    /// The longest provider-authored string kept, in characters.
    ///
    /// A window's display name and a plan name both come from a provider and neither is
    /// bounded at the wire. Truncating here is what turns the file's size limit from an
    /// assertion into arithmetic.
    public static let maximumProviderStringLength = 128

    // MARK: - Derived bounds

    /// The largest history file this product can author, with headroom.
    ///
    /// Measured, not estimated. `UsageHistorySizeTests` builds a fleet that reaches every
    /// cap above at once — five accounts, eight windows each, every ring at capacity, every
    /// ledger full, every provider-authored name at the maximum length — and encodes it
    /// through the shipping encoder:
    ///
    ///     one sample ............... 11 bytes of timestamp + 6 of basis points   ~17 bytes
    ///     one full ring ............ 768 samples                              ~13 000 bytes
    ///     one full ledger .......... 64 completed windows                      ~4 300 bytes
    ///     one account, full ........ 8 windows                                ~141 000 bytes
    ///     five accounts ............ the product cap                           705 712 bytes
    ///
    /// 1 MiB is the next power of two above that, so the pathological legal maximum still
    /// fits and the writer never authors bytes the reader would refuse. A real fleet — four
    /// accounts, four windows each, eight days at the fifteen-minute idle tier — measures
    /// 177 KB, and the same test pins that too.
    public static let maximumHistoryBytes = 1024 * 1024

    /// The largest snapshot file this product can author, with headroom.
    ///
    /// Five accounts, eight readings each with a scoped name, a plan, overage figures and
    /// credits, measures 4 052 bytes. 64 KiB is far above that and still small enough to
    /// read on the launch path without anybody having to think about it.
    public static let maximumSnapshotBytes = 64 * 1024

    // MARK: - Helpers

    /// The sampling tier one window falls in, from its own length.
    public static func isFineGrained(periodSeconds: TimeInterval) -> Bool {
        periodSeconds > 0 && periodSeconds <= fineGrainedWindowCeiling
    }

    public static func sampleSpacing(periodSeconds: TimeInterval) -> TimeInterval {
        isFineGrained(periodSeconds: periodSeconds) ? fineSampleSpacing : coarseSampleSpacing
    }

    public static func sampleHorizon(periodSeconds: TimeInterval) -> TimeInterval {
        isFineGrained(periodSeconds: periodSeconds) ? fineSampleHorizon : coarseSampleHorizon
    }

    /// A provider string, cut to the bound that makes the file's size derivable.
    ///
    /// Cut by Character, so a name ending in an emoji or a combining mark is shortened to a
    /// name and never to half a grapheme.
    public static func bounded(_ value: String) -> String {
        guard value.count > maximumProviderStringLength else { return value }
        return String(value.prefix(maximumProviderStringLength))
    }

    /// Which limit a ring belongs to: the provider's own name for it, and the window's
    /// length, exactly as `UsageReading.id` composes them — over the **bounded** name.
    ///
    /// Composed here rather than by truncating `UsageReading.id`, because truncating the
    /// composite can cut the length off the end. A provider that scoped two windows of
    /// different lengths to one very long model name would then have both fall into one
    /// ring, and the merge would be silent. The length is never the part that is lost.
    public static func windowKey(scope: String?, period: PersistedUsagePeriod) -> String {
        let length: String = switch period {
        case .session: "session"
        case .weekly: "weekly"
        case .other(let seconds): "s\(Int(seconds.rounded()))"
        }
        guard let scope else { return length }
        return "\(bounded(scope))|\(length)"
    }
}
