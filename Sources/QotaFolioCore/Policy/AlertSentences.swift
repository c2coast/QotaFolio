import Foundation

/// **What an alert says.** One informational sentence per alert, rendered from the assessment
/// the brain published, through the catalog. It names the account, the time and the level. It
/// never tells the person what to do: there is no button behind it and no verb in it.
public nonisolated enum AlertSentences {
    /// The notification's body for `alert`, or nil when the assessment no longer knows the
    /// account it is about — an alert that outlived its account has nothing to say.
    public static func body(
        for alert: FleetAlert,
        in assessment: FleetAssessment,
        style: SentenceStyle
    ) -> String? {
        guard let account = assessment.assessment(for: alert.account) else { return nil }
        let name = account.account.name

        switch alert.kind {
        case .runningOut(let at, let windowKey, let alternative):
            let clock = PanelWords.clock(at, style: style)
            let window = account.windows.first { $0.windowKey == windowKey }
            let otherClause = alternative
                .flatMap { assessment.assessment(for: $0) }
                .flatMap { other -> String? in
                    guard let left = other.sessionRemainingPercent else { return nil }
                    return qfLocalized(
                        "alert.runningOut.other",
                        defaultValue: " \(other.account.name) has \(PanelWords.percent(AssessmentSentences.whole(left), style: style)).",
                        comment: "Clause appended to a running-out alert, naming another account and what it has left now. Leading space included. An account name, then a percentage."
                    )
                } ?? ""
            if let reset = window?.resetsAt, reset > at {
                let before = SpokenDuration.spoken(seconds: Int(reset.timeIntervalSince(at)))
                return qfLocalized(
                    "alert.runningOut.beforeReset",
                    defaultValue: "\(name) runs out at \(clock) at this pace — \(before) before its reset.\(otherClause)",
                    comment: "Alert body when an account's window runs dry before its reset. The account, the clock time it runs out, how long before the reset, then the other-account clause or nothing."
                )
            }
            return qfLocalized(
                "alert.runningOut",
                defaultValue: "\(name) runs out at \(clock) at this pace.\(otherClause)",
                comment: "Alert body when an account's window runs dry and no reset time is known. The account, the clock time it runs out, then the other-account clause or nothing."
            )

        case .freshWindow(let windowKey, _):
            let window = account.windows.first { $0.windowKey == windowKey }
            if let scope = window?.scope {
                return qfLocalized(
                    "alert.fresh.scoped",
                    defaultValue: "\(name) reset — a fresh \(scope) window.",
                    comment: "Alert body when a model-scoped window has just turned over. The account, then the scope's name as the provider spells it."
                )
            }
            if window?.period == .weekly {
                return qfLocalized(
                    "alert.fresh.weekly",
                    defaultValue: "\(name) reset — a fresh week.",
                    comment: "Alert body when an account's weekly window has just turned over. The argument is the account name."
                )
            }
            return qfLocalized(
                "alert.fresh.session",
                defaultValue: "\(name) reset — a fresh five-hour window.",
                comment: "Alert body when an account's five-hour window has just turned over. The argument is the account name."
            )

        case .stranding(let percent, let expiresAt):
            return qfLocalized(
                "alert.stranding",
                defaultValue: "\(name): about \(PanelWords.percent(AssessmentSentences.whole(percent), style: style)) of the week expires \(PanelWords.weekday(expiresAt, style: style)).",
                comment: "Alert body when part of an account's week will expire unused. The account, a percentage, then the weekday it expires."
            )
        }
    }
}
