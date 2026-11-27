import Foundation

/// **The account's own numbers.** The line an opened card shows under its rows: the extra usage
/// spent against its monthly cap, or the prepaid credits, or neither.
public nonisolated enum PlanSentences {
    /// "Extra usage £12.40 of £150.00 this month"
    public static func extraUsage(_ extra: ExtraUsage, limit: Double, style: SentenceStyle) -> String {
        qfLocalized(
            "plan.extraUsage",
            defaultValue: "Extra usage \(PanelWords.money(extra.usedCredits, currency: extra.currency, style: style)) of \(PanelWords.money(limit, currency: extra.currency, style: style)) this month",
            comment: "Plan line for overage spend against a monthly cap. The amount spent, then the cap, both in the provider's currency."
        )
    }

    /// "796 credits ($31.84)" or "796 credits"
    public static func credits(_ credits: UsageCredits, style: SentenceStyle) -> String {
        guard let dollars = credits.dollars else {
            return qfLocalized(
                "plan.credits",
                defaultValue: "\(credits.count) credits",
                comment: "Plan line for prepaid credits when the app has no dollar rate for them."
            )
        }
        return qfLocalized(
            "plan.credits.value",
            defaultValue: "\(credits.count) credits (\(PanelWords.money(dollars, currency: "USD", style: style)))",
            comment: "Plan line for prepaid credits: the count, then their dollar value."
        )
    }

    public static func noExtraUsage() -> String {
        qfLocalized("plan.noExtraUsage", defaultValue: "No extra usage", comment: "Plan line when the account has no overage billing and no prepaid credits.")
    }
}
