import Foundation

public nonisolated struct CatalogAdvisoryPresentation: Equatable, Sendable {
    public let message: String
    public let accessibilityValue: String

    public init(message: String, accessibilityValue: String) {
        self.message = message
        self.accessibilityValue = accessibilityValue
    }

    /// The advisory, in the words a user reads.
    ///
    /// Three facts are told apart here, and the instruction each carries is the reason they are
    /// told apart at all:
    ///
    /// - **Durably corrupt.** The bytes were read and they are not a catalog. Reading them again
    ///   produces the same verdict, so the copy says the list is damaged and says plainly that
    ///   reopening will not repair it.
    /// - **Temporarily unreadable.** The read never happened, so nothing about the catalog and
    ///   nothing about the sign-ins is claimed. The surface that renders this offers the retry,
    ///   so the copy does not send the user out of the app for it.
    /// - **Credential store unreachable.** A separate fact about the Keychain, and the only one of
    ///   the three whose re-check really does need a relaunch, because the enumeration runs at
    ///   startup. Its copy says so.
    public static func make(
        advisory: CatalogRecoveryAdvisory,
        loadState: CatalogLoadState
    ) -> CatalogAdvisoryPresentation? {
        switch advisory {
        case .credentialsWithoutCatalog(let count):
            switch loadState {
            case .missing:
                let message = count == 1
                    ? qfLocalized(
                        "catalog.advisory.credentialsWithoutCatalog.one",
                        defaultValue: "QotaFolio's account list is missing, but 1 saved sign-in is still in your Mac's Keychain. Nothing has been deleted. Add your account again to continue.",
                        comment: "Recovery advisory when one Keychain credential survives a missing account catalog."
                    )
                    : qfLocalized(
                        "catalog.advisory.credentialsWithoutCatalog.many",
                        defaultValue: "QotaFolio's account list is missing, but \(count) saved sign-ins are still in your Mac's Keychain. Nothing has been deleted. Add your accounts again to continue.",
                        comment: "Recovery advisory when multiple Keychain credentials survive a missing account catalog."
                    )
                return CatalogAdvisoryPresentation(message: message, accessibilityValue: message)
            case .unreadable:
                let message = count == 1
                    ? qfLocalized(
                        "catalog.advisory.credentialsUnreadableCatalog.one",
                        defaultValue: "1 saved sign-in is still in your Mac's Keychain, so do not sign in again yet. Adding and changing accounts stays unavailable while the list is damaged.",
                        comment: "Recovery advisory when one Keychain credential survives a durably damaged account catalog."
                    )
                    : qfLocalized(
                        "catalog.advisory.credentialsUnreadableCatalog.many",
                        defaultValue: "\(count) saved sign-ins are still in your Mac's Keychain, so do not sign in again yet. Adding and changing accounts stays unavailable while the list is damaged.",
                        comment: "Recovery advisory when multiple Keychain credentials survive a durably damaged account catalog."
                    )
                return CatalogAdvisoryPresentation(message: message, accessibilityValue: message)
            case .loading, .loaded:
                return nil
            }

        case .catalogTemporarilyUnreadable:
            switch loadState {
            case .unreadable:
                let message = qfLocalized(
                    "catalog.advisory.temporarilyUnreadable",
                    defaultValue: "Nothing about your saved sign-ins has changed. Adding and changing accounts stays unavailable until the list loads.",
                    comment: "Recovery advisory when the account catalog read never happened and a retry is offered."
                )
                return CatalogAdvisoryPresentation(message: message, accessibilityValue: message)
            case .loading, .loaded, .missing:
                return nil
            }

        case .credentialStoreUnreachable:
            switch loadState {
            case .missing:
                let message = qfLocalized(
                    "catalog.advisory.storeUnreachable",
                    defaultValue: "QotaFolio couldn't check your saved sign-ins, so it doesn't know which of them are still there. Nothing has been deleted or changed. Quit and reopen QotaFolio to let it check again, or add an account now.",
                    comment: "Recovery advisory when the account catalog is missing and the credential store could not be checked."
                )
                return CatalogAdvisoryPresentation(message: message, accessibilityValue: message)
            case .unreadable:
                let message = qfLocalized(
                    "catalog.advisory.storeUnreachableUnreadableCatalog",
                    defaultValue: "QotaFolio also couldn't check your saved sign-ins, so it doesn't know which of them remain. Nothing has been deleted or changed, so do not sign in again yet. Adding and changing accounts stays unavailable while the list is damaged.",
                    comment: "Recovery advisory when the account catalog is durably damaged and the credential store could not be checked."
                )
                return CatalogAdvisoryPresentation(message: message, accessibilityValue: message)
            case .loading, .loaded:
                return nil
            }
        }
    }
}
