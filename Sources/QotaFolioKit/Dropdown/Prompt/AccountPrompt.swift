import Observation
import QotaFolioCore

/// Which account the panel is asking about, and what it is asking.
///
/// The panel asks inline, in its own window. A SwiftUI `.sheet` is a second `NSWindow`, and the
/// dismissal monitor classifies every click and keystroke inside one as an outside click — it
/// tears the panel down before the button can fire. A prompt that lives in the panel's own window
/// is reached by the same clicks the account rows are reached by.
public nonisolated enum AccountPrompt: Equatable, Sendable {
    case rename(AccountID)
    case remove(AccountID)

    public var accountID: AccountID {
        switch self {
        case .rename(let id), .remove(let id): id
        }
    }
}

/// Why a rename did not reach the device.
///
/// `AccountListView.renameAccount` answers with this rather than the admission's verdict alone: a
/// catalog that turns unreadable while the prompt is open gives a permitted write, an unchanged
/// name and an announcement that the rename happened.
public nonisolated enum AccountRenameRefusal: Equatable, Sendable {
    /// The app is quitting, and it holds account changes closed until the process exits.
    case accountChangesAreClosed
    /// The account list could not be read, so it could not be written either.
    case accountListUnreadable
    /// The list was asked and the account still carries its old name.
    case renameWasNotApplied
}

/// The answer a prompt shows when its button did nothing.
public nonisolated enum AccountPromptRefusal: Equatable, Sendable {
    case rename(AccountRenameRefusal)
    case removal(AccountRemovalRefusal)
}

/// Why the name on the device is unchanged, in the words a user reads and VoiceOver speaks.
public nonisolated func accountRenameRefusalReason(_ refusal: AccountRenameRefusal) -> String {
    switch refusal {
    case .accountChangesAreClosed:
        qfLocalized(
            "rename.refused.finishingQuit",
            defaultValue: "QotaFolio is finishing quitting. The name was not changed.",
            comment: "Shown in the rename prompt while a quit holds account changes closed."
        )
    case .accountListUnreadable:
        qfLocalized(
            "rename.refused.unreadable",
            defaultValue: "QotaFolio cannot read your account list right now. The name was not changed.",
            comment: "Shown in the rename prompt when the account list became unreadable before the new name was written."
        )
    case .renameWasNotApplied:
        qfLocalized(
            "rename.refused.notApplied",
            defaultValue: "QotaFolio could not change this name. The account still uses its old name.",
            comment: "Shown in the rename prompt when the account list was written and the new name is not there."
        )
    }
}

/// Why the account is still in the list, in the words a user reads and VoiceOver speaks.
///
/// One sentence per guard `AccountLifecycleCoordinator.removeAccount` returns on. Adding a guard
/// there adds a case here, and adding a case here is what makes the compiler ask for a sentence.
public nonisolated func accountRemovalRefusalReason(_ refusal: AccountRemovalRefusal) -> String {
    switch refusal {
    case .accountChangesAreClosed:
        qfLocalized(
            "remove.refused.finishingQuit",
            defaultValue: "This account was not removed. QotaFolio is finishing quitting, and nothing is being deleted.",
            comment: "Shown in the remove prompt when a quit holds account changes closed. Nothing is being deleted."
        )
    case .accountListUnreadable:
        qfLocalized(
            "remove.refused.unreadable",
            defaultValue: "QotaFolio cannot read your account list right now. This account was not removed.",
            comment: "Shown in the remove prompt when the account list could not be read."
        )
    case .accountAlreadyRemoved:
        qfLocalized(
            "remove.refused.alreadyRemoved",
            defaultValue: "This account is no longer in your list.",
            comment: "Shown in the remove prompt when the account had already gone before Remove was pressed."
        )
    case .removalWasNotApplied:
        qfLocalized(
            "remove.refused.notApplied",
            defaultValue: "QotaFolio could not remove this account. It is still in your list.",
            comment: "Shown in the remove prompt when the account list was asked to remove the account and it is still there."
        )
    }
}

/// Why the account is still signed out, in the words a user reads and VoiceOver speaks.
///
/// One sentence per case of `AccountReconnectRefusal`, and every one of them leads with the press.
/// The user pressed a button and nothing happened; "Reconnecting did not start" is the fact they
/// are missing, and it is the one clause here that can never stop being true. The cause follows,
/// in the tense it is true in: an admission stays closed for as long as the operation that closed
/// it runs, while a sign-in that was in progress can be over by the time this is read.
public nonisolated func accountReconnectRefusalReason(_ refusal: AccountReconnectRefusal) -> String {
    switch refusal {
    case .accountChangesAreClosed:
        qfLocalized(
            "reconnect.refused.finishingQuit",
            defaultValue: "Reconnecting did not start. QotaFolio is finishing quitting, and nothing is being deleted.",
            comment: "Shown on an account card when a quit holds account changes closed and Reconnect was pressed. Nothing is being deleted."
        )
    case .anotherAccountFlowIsOpen:
        qfLocalized(
            "reconnect.refused.flowOpen",
            defaultValue: "Reconnecting did not start. QotaFolio was already signing in to an account.",
            comment: "Shown on an account card when Reconnect was pressed while another account sign-in was already running."
        )
    case .accountListUnreadable:
        qfLocalized(
            "reconnect.refused.unreadable",
            defaultValue: "Reconnecting did not start. QotaFolio cannot read your account list right now.",
            comment: "Shown on an account card when the account list could not be read and Reconnect was pressed."
        )
    case .accountIsNoLongerListed:
        qfLocalized(
            "reconnect.refused.notListed",
            defaultValue: "Reconnecting did not start. This account is no longer in your list.",
            comment: "Shown on an account card when Reconnect was pressed for an account that has left the list."
        )
    }
}

/// The account whose Reconnect did nothing, and why.
///
/// The account travels with the refusal because five cards can be on screen and only one of them
/// was pressed. A sentence on the wrong card is a sentence about an account that is working.
public nonisolated struct AccountReconnectRefusalRecord: Equatable, Sendable {
    public let accountID: AccountID
    public let refusal: AccountReconnectRefusal

    public init(accountID: AccountID, refusal: AccountReconnectRefusal) {
        self.accountID = accountID
        self.refusal = refusal
    }
}

/// Records the answer a Reconnect press produced, wherever the press came from.
///
/// Two controls start a reconnect — the card's own button, and the Reconnect item in the row's
/// actions menu — and a third, the banner button on a card that still shows its last known
/// numbers. All three end here, so the sentence and the announcement cannot differ between them.
///
/// The announcement is not conditional on there being somewhere to write the sentence: a
/// VoiceOver user in any build hears it at the moment of the press, which is the moment they are
/// asking about.
@MainActor public func recordReconnectAnswer(
    _ refusal: AccountReconnectRefusal?,
    for accountID: AccountID,
    in questions: AccountPromptState?
) {
    guard let refusal else {
        questions?.clearReconnectRefusal()
        return
    }
    questions?.refuseReconnect(accountID, refusal)
    AccessibilityAnnouncer.announce(accountReconnectRefusalReason(refusal))
}

/// The sentence a refused prompt prints.
public nonisolated func accountPromptRefusalReason(_ refusal: AccountPromptRefusal) -> String {
    switch refusal {
    case .rename(let rename): accountRenameRefusalReason(rename)
    case .removal(let removal): accountRemovalRefusalReason(removal)
    }
}

/// Records the answer a prompt's confirming button produced, and says it out loud.
///
/// Both of the panel's questions end here — the remove confirmation's **Remove** and the rename
/// prompt's **Save** — so neither the sentence, nor the announcement, nor the moment either
/// happens can differ between them. It is the shape `recordReconnectAnswer` gave the card's three
/// Reconnect controls, applied to the two controls the panel asks its questions with.
///
/// One press, one announcement, never zero and never stale. On the refusal path it is the sentence
/// the prompt prints; on the success path it is the layout change that says the question is gone
/// and the rows are back.
///
/// Focus is not moved, and the reason is not caution. The pressed button is still on screen, still
/// the thing the user wants next, and the only place to move focus to is the caption — which is
/// not a control, so it is a dead end. What changed is what the button MEANS, so the button is
/// what changes: it carries the same sentence as its hint. Three routes to one answer — heard at
/// the press, read off the control on the way back to it, and reached by ordinary navigation.
@MainActor public func recordPromptAnswer(
    _ refusal: AccountPromptRefusal?,
    in questions: AccountPromptState
) {
    guard let refusal else {
        questions.clear()
        AccessibilityAnnouncer.layoutChanged()
        return
    }
    questions.refuse(refusal)
    // Not conditional on there being anywhere to write the sentence, for the reason
    // `recordReconnectAnswer` is not: `refuse(_:)` drops a refusal that has no prompt on screen,
    // and a user who pressed the button is owed the answer either way.
    AccessibilityAnnouncer.announce(accountPromptRefusalReason(refusal))
}

/// The account a prompt is about, resolved against the rows on screen.
///
/// One derivation with two readers. `PanelContentView` uses it to decide the panel's body and
/// `AccountListView` uses it to decide what it draws; two derivations of the same question could
/// disagree, and a disagreement here draws a prompt inside a scrolling list with a footer under it.
/// A prompt whose account has left the list resolves to nil, so a row removed underneath it takes
/// its prompt with it rather than leaving a question about an account that is gone.
public nonisolated func promptedAccount(
    _ prompt: AccountPrompt?,
    in accounts: [AccountConfig]
) -> AccountConfig? {
    guard let prompt else { return nil }
    return accounts.first { $0.id == prompt.accountID }
}

/// What the panel is asking about one account, and what it was told when a control did nothing —
/// for as long as the panel is on screen.
///
/// This is panel state, not view state, and the difference is load-bearing. The panel's hosting
/// controller is built once and never torn down, so a `@State` confirmation would still be there
/// the next time the user opened the panel — a destructive question they never asked, aimed at
/// whichever account happened to still match. `MenuBarPanelController` owns this object and clears
/// it whenever the panel leaves the screen, which is the same instant the user stops being able to
/// answer the question.
@MainActor @Observable public final class AccountPromptState {
    public private(set) var prompt: AccountPrompt?
    public private(set) var refusal: AccountPromptRefusal?

    /// The account whose Reconnect did nothing, and why, or nil while nothing has been refused.
    ///
    /// It lives here rather than in the card because the card cannot own it. The panel's hosting
    /// controller is built once and never torn down, so a refusal held as view state would still
    /// be on the card at the next visit — a sentence about a quit that finished, or about a list
    /// that is readable again. This object is cleared the moment the panel leaves the screen,
    /// which is the moment the sentence stops being about anything the user can see.
    public private(set) var reconnectRefusal: AccountReconnectRefusalRecord?

    public init() {}

    /// What the panel's height depends on. See `AccountPromptStep`.
    public var step: AccountPromptStep? {
        switch prompt {
        case .rename?: .rename(isRefused: refusal != nil)
        case .remove?: .remove(isRefused: refusal != nil)
        case nil: nil
        }
    }

    /// The sentence a refused prompt prints, or nil while nothing has been refused.
    public var refusalReason: String? {
        refusal.map(accountPromptRefusalReason)
    }

    public func ask(_ prompt: AccountPrompt) {
        self.prompt = prompt
        refusal = nil
    }

    /// Records why the prompt's button did nothing. A refusal with no prompt on screen has nobody
    /// to tell, so it is dropped rather than kept for a later, unrelated question.
    public func refuse(_ refusal: AccountPromptRefusal) {
        guard prompt != nil else { return }
        self.refusal = refusal
    }

    /// Records why one account's Reconnect did nothing.
    ///
    /// Unconditional, unlike `refuse(_:)` above. A prompt refusal with no prompt on screen has
    /// nobody to tell; this one always has somebody — the card the account is drawn on is on
    /// screen exactly when the press that produced it was possible.
    public func refuseReconnect(_ accountID: AccountID, _ refusal: AccountReconnectRefusal) {
        reconnectRefusal = AccountReconnectRefusalRecord(accountID: accountID, refusal: refusal)
    }

    /// Drops the reconnect refusal, because a later press started the sign-in the earlier one
    /// could not.
    public func clearReconnectRefusal() {
        reconnectRefusal = nil
    }

    /// The sentence one account's card prints, or nil when that card has nothing to answer for.
    public func reconnectRefusalReason(for accountID: AccountID) -> String? {
        guard let record = reconnectRefusal, record.accountID == accountID else { return nil }
        return accountReconnectRefusalReason(record.refusal)
    }

    public func clear() {
        prompt = nil
        refusal = nil
        reconnectRefusal = nil
    }
}
