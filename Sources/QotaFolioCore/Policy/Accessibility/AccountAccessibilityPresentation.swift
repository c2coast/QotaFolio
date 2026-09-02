import Foundation

/// What VoiceOver says for one account's card: one informational sentence.
///
/// The card collapses its children and speaks this instead, so a VoiceOver user hears an
/// account the way a sighted user sees one — the name, the plan, then each window's level and
/// its reset — rather than walking a header, three rows and a menu. Nothing in it directs:
/// no "use", no recommendation, no plan. The app shows.
public nonisolated struct AccountAccessibilityPresentation: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    /// The sentence for one account, from the same face the card draws.
    public static func make(
        account: AccountConfig,
        face: AccountFace,
        now: Date,
        style: SentenceStyle,
        namesHidden: Bool = false
    ) -> AccountAccessibilityPresentation {
        let provider = account.provider == .anthropic
            ? qfLocalized("provider.anthropic", defaultValue: "Anthropic", comment: "Anthropic provider name.")
            : qfLocalized("provider.openai", defaultValue: "ChatGPT", comment: "ChatGPT provider name.")
        let label = qfLocalized(
            "account.ax.label",
            defaultValue: "\(presentedAccountName(account, namesHidden: namesHidden)), \(provider)",
            comment: "VoiceOver label for an account card: the user's name for the account, then the provider."
        )

        var clauses: [String] = []
        if let plan = face.planName {
            clauses.append(qfLocalized(
                "face.ax.plan",
                defaultValue: "\(plan).",
                comment: "VoiceOver clause naming the account's plan, as the provider spells it."
            ))
        }

        switch face.body {
        case .needsSignIn:
            clauses.append(qfLocalized("face.needsSignIn.sentence", defaultValue: "Needs sign-in.", comment: "Complete sentence stating that the account's grant has lapsed and the person signs in again."))
        case .waitingForFirstReading:
            clauses.append(qfLocalized("face.waiting.sentence", defaultValue: "Waiting for the first reading.", comment: "Complete sentence stating that the account is connected and its first reading has not arrived."))
        case .setupIssue:
            clauses.append(qfLocalized("face.setupIssue.sentence", defaultValue: "Setup issue.", comment: "Complete sentence stating that the account cannot be polled until it is repaired."))
        case .noReading:
            clauses.append(qfLocalized("face.noReading.sentence", defaultValue: "No reading.", comment: "Complete sentence stating that the provider answered with nothing usable and no earlier number exists."))
        case .windows(let levels):
            if face.isSpent {
                if let back = face.returnsAt {
                    clauses.append(qfLocalized(
                        "face.ax.spentBack",
                        defaultValue: "Spent, back at \(PanelWords.clock(back, style: style)).",
                        comment: "VoiceOver clause for an account with nothing spendable now, and the clock time it comes back."
                    ))
                } else {
                    clauses.append(qfLocalized("face.ax.spent", defaultValue: "Spent.", comment: "VoiceOver clause for an account with nothing spendable now and no return time reported."))
                }
            }
            for level in levels {
                clauses.append(windowClause(level, now: now, style: style))
            }
            if face.needsSignIn {
                clauses.append(qfLocalized("face.needsSignIn.sentence", defaultValue: "Needs sign-in.", comment: "Complete sentence stating that the account's grant has lapsed and the person signs in again."))
            } else if face.hasSetupIssue {
                clauses.append(qfLocalized("face.setupIssue.sentence", defaultValue: "Setup issue.", comment: "Complete sentence stating that the account cannot be polled until it is repaired."))
            }
            if face.isLastKnown, let observedAt = face.observedAt {
                clauses.append(qfLocalized(
                    "face.ax.asOf",
                    defaultValue: "Numbers as of \(PanelWords.clock(observedAt, style: style)).",
                    comment: "VoiceOver clause saying the numbers on the card are the last known ones, with the clock time they were true at."
                ))
            }
        }

        return AccountAccessibilityPresentation(label: label, value: clauses.joined(separator: " "))
    }

    /// One window: its name, its level, and its reset.
    ///
    /// "low" is inserted at a fifth left, because the bar it describes is red there and the
    /// colour must never be the only thing that says so. A spent window says spent instead of
    /// a number, because its bar is full.
    static func windowClause(_ level: UsageWindowLevel, now: Date, style: SentenceStyle) -> String {
        var clause: String
        if level.isSpent {
            clause = qfLocalized(
                "face.ax.window.spent",
                defaultValue: "\(level.title), spent.",
                comment: "VoiceOver clause for one quota window with nothing left in it. The argument is the window's name."
            )
        } else if level.isLow {
            clause = qfLocalized(
                "face.ax.window.low",
                defaultValue: "\(level.title), \(level.wholePercentUsed) percent used, low.",
                comment: "VoiceOver clause for one quota window at a fifth or less left. The window's name, then the whole percentage used."
            )
        } else {
            clause = qfLocalized(
                "face.ax.window",
                defaultValue: "\(level.title), \(level.wholePercentUsed) percent used.",
                comment: "VoiceOver clause for one quota window. The window's name, then the whole percentage used."
            )
        }
        if let resetsAt = level.resetsAt {
            let countdown = ResetCountdown.make(
                resetsAt: resetsAt,
                now: now,
                locale: style.locale,
                calendar: style.calendar,
                timeZone: style.timeZone
            )
            switch countdown.state {
            case .future:
                clause += " " + qfLocalized(
                    "face.ax.resetsIn",
                    defaultValue: "Resets in \(countdown.spoken).",
                    comment: "VoiceOver clause for a window's reset countdown. The argument is the spoken duration."
                )
            case .due, .unavailable:
                clause += " " + countdown.spoken + "."
            }
        }
        return clause
    }
}
