import Foundation

public nonisolated enum AXIdentifiers {
    public static let statusItem = "qotafolio.statusItem"
    public static let panel = "qotafolio.panel"
    public static let panelHeading = "qotafolio.panel.heading"
    public static let accountList = "qotafolio.accounts.list"
    public static let catalogRecoveryAdvisory = "qotafolio.catalog.recoveryAdvisory"
    public static let authHeading = "qotafolio.auth.add.heading"
    public static let authError = "qotafolio.auth.error"
    public static let authNameField = "qotafolio.auth.nameField"
    public static let authProvider = "qotafolio.auth.provider"
    public static let authContinue = "qotafolio.auth.continue"
    public static let authCancel = "qotafolio.auth.cancel"
    public static let authDismissFailure = "qotafolio.auth.dismissFailure"
    public static let authDisclosure = "qotafolio.auth.disclosure"
    public static let chatGPTCode = "qotafolio.auth.chatgpt.code"
    public static let chatGPTCopyCode = "qotafolio.auth.chatgpt.copyCode"
    public static let chatGPTOpenVerification = "qotafolio.auth.chatgpt.openVerification"
    public static let chatGPTCopyVerificationURL = "qotafolio.auth.chatgpt.copyVerificationURL"
    public static let chatGPTStatus = "qotafolio.auth.chatgpt.status"
    public static let chatGPTGetNewCode = "qotafolio.auth.chatgpt.getNewCode"
    public static let chatGPTRetry = "qotafolio.auth.chatgpt.retry"
    public static let anthropicStatus = "qotafolio.auth.anthropic.status"
    public static let anthropicOpenBrowser = "qotafolio.auth.anthropic.openBrowser"
    public static let anthropicRetry = "qotafolio.auth.anthropic.retry"
    public static let accountPrompt = "qotafolio.account.prompt"
    public static let accountPromptCaption = "qotafolio.account.prompt.caption"
    public static let renameField = "qotafolio.account.rename.field"
    public static let renameSave = "qotafolio.account.rename.save"
    public static let renameCancel = "qotafolio.account.rename.cancel"
    public static let removeConfirm = "qotafolio.account.remove.confirm"
    public static let removeCancel = "qotafolio.account.remove.cancel"
    public static let footerAddAccount = "qotafolio.footer.addAccount"
    public static let footerRefresh = "qotafolio.footer.refresh"
    public static let footerSettings = "qotafolio.footer.settings"
    public static let footerQuit = "qotafolio.footer.quit"
    public static let footerMore = "qotafolio.footer.more"
    public static let menuBarPlacementAdvisory = "qotafolio.panel.placementAdvisory"
    public static let settingsAccountsAdd = "qotafolio.settings.accounts.addAccount"
    public static let settingsUninstall = "qotafolio.settings.uninstall"
    public static let uninstallConfirmation = "qotafolio.uninstall.confirmation"
    public static let uninstallConfirm = "qotafolio.uninstall.confirm"
    public static let uninstallCancel = "qotafolio.uninstall.cancel"
    public static let uninstallProgress = "qotafolio.uninstall.progress"
    public static let uninstallFailure = "qotafolio.uninstall.failure"
    public static let uninstallRetry = "qotafolio.uninstall.retry"
    public static let uninstallSuccess = "qotafolio.uninstall.success"
    public static let uninstallShowInFinder = "qotafolio.uninstall.showInFinder"

    public static func accountSummary(_ id: AccountID) -> String {
        "qotafolio.account.\(id.rawValue.uuidString.lowercased()).summary"
    }

    public static func accountMoreActions(_ id: AccountID) -> String {
        "qotafolio.account.\(id.rawValue.uuidString.lowercased()).moreActions"
    }

    public static func accountReauthenticate(_ id: AccountID) -> String {
        "qotafolio.account.\(id.rawValue.uuidString.lowercased()).reauthenticate"
    }

    /// The caption an account card prints because a Reconnect press did nothing. Same shape as
    /// every account-scoped identifier beside it.
    public static func accountReconnectRefusal(_ id: AccountID) -> String {
        "qotafolio.account.\(id.rawValue.uuidString.lowercased()).reconnectRefusal"
    }

    public static func accountRetry(_ id: AccountID) -> String {
        "qotafolio.account.\(id.rawValue.uuidString.lowercased()).retry"
    }

    public static func accountOpenSettings(_ id: AccountID) -> String {
        "qotafolio.account.\(id.rawValue.uuidString.lowercased()).openSettings"
    }

    public static func accountMoveUp(_ id: AccountID) -> String {
        "qotafolio.account.\(id.rawValue.uuidString.lowercased()).moveUp"
    }

    public static func accountMoveDown(_ id: AccountID) -> String {
        "qotafolio.account.\(id.rawValue.uuidString.lowercased()).moveDown"
    }

    public static func meter(_ accountID: AccountID, kind: UsageWindowKind) -> String {
        "qotafolio.account.\(accountID.rawValue.uuidString.lowercased()).meter.\(kind.rawValue)"
    }
}
