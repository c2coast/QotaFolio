import SwiftUI
import QotaFolioCore

/// The takeover shown instead of the account list when the catalog cannot be served.
///
/// It never renders an empty account list. "We could not read it" and "you have no accounts" are
/// different sentences and only one of them can be true here, so the rows stay hidden behind this
/// view rather than being drawn as an empty, reassuring list.
///
/// It tells two different truths, because the catalog has two different failures:
///
/// - **The list is damaged.** The bytes were read and they are not a catalog. Reading them again
///   produces the same verdict, so there is no retry to offer and the copy says plainly that
///   reopening will not repair it.
/// - **The list could not be read just now.** A descriptor shortage, a momentarily unusable
///   anchor. Nothing was learned about the catalog, `AccountCatalog.load()` will read again, and
///   this view offers exactly that.
public struct CatalogUnreadableView: View {
    public let advisory: CatalogRecoveryAdvisory?

    /// True when the last read never happened, so reading again is meaningful.
    public let canRetry: Bool

    /// Performs the retry and answers whether the catalog is readable now.
    ///
    /// The answer is what the view says out loud. A retry that changes nothing looks identical to
    /// a retry that was never pressed, and a button that reports nothing is a button a VoiceOver
    /// user cannot tell the outcome of.
    public let retry: () -> Bool

    @Environment(\.openQotaFolioSettings) private var openSettings

    public init(
        advisory: CatalogRecoveryAdvisory?,
        canRetry: Bool,
        retry: @escaping () -> Bool
    ) {
        self.advisory = advisory
        self.canRetry = canRetry
        self.retry = retry
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Label {
                    Text(qfLocalized("catalog.unreadable.title", defaultValue: "Account list unavailable", comment: "Global error title when the saved account catalog is unreadable."))
                        .font(.title3.weight(.semibold))
                } icon: {
                    Image(systemName: "exclamationmark.diamond.fill")
                        .foregroundStyle(.red)
                }
                .accessibilityAddTraits(.isHeader)

                Text(explanation)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let advisory {
                    CatalogRecoveryAdvisoryRow(advisory: advisory, loadState: .unreadable)
                }

                HStack {
                    if canRetry {
                        Button {
                            performRetry()
                        } label: {
                            Label(
                                qfLocalized("action.tryAgain", defaultValue: "Try again", comment: "Start a fresh attempt after a failure."),
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minWidth: 40, minHeight: 40)
                        .accessibilityIdentifier("qotafolio.catalog.unreadable.retry")
                    }

                    Button {
                        openSettings()
                    } label: {
                        Label(
                            qfLocalized("action.openSettings", defaultValue: "Open Settings", comment: "Open QotaFolio Settings."),
                            systemImage: "gearshape"
                        )
                    }
                    .frame(minWidth: 40, minHeight: 40)
                    .accessibilityIdentifier(AXIdentifiers.footerSettings)

                    Spacer()

                    Button {
                        requestQotaFolioTermination()
                    } label: {
                        Label(
                            qfLocalized("footer.quit", defaultValue: "Quit QotaFolio", comment: "Button that quits QotaFolio, in the panel footer and on the screen shown when the account list cannot be read."),
                            systemImage: "power"
                        )
                    }
                    .frame(minWidth: 40, minHeight: 40)
                    .accessibilityIdentifier(AXIdentifiers.footerQuit)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        }
    }

    /// The catalog-axis sentence. The advisory row below it carries the credential-axis one, so
    /// neither repeats the other.
    var explanation: String {
        canRetry
            ? qfLocalized(
                "catalog.unreadable.body.temporary",
                defaultValue: "QotaFolio couldn't read its saved accounts just now. Nothing has been deleted, and the list may load on the next attempt.",
                comment: "Unreadable-catalog guidance when the read never happened and an in-app retry is offered."
            )
            : qfLocalized(
                "catalog.unreadable.body.damaged",
                defaultValue: "QotaFolio's saved account list is damaged, so it can't be read. Nothing has been deleted. Reopening QotaFolio won't repair the list — Settings has the option to remove QotaFolio and start over.",
                comment: "Unreadable-catalog guidance when the saved bytes are durably corrupt."
            )
    }

    private func performRetry() {
        guard retry() else {
            AccessibilityAnnouncer.announce(
                qfLocalized(
                    "catalog.unreadable.retryFailed",
                    defaultValue: "QotaFolio still couldn't read its saved accounts.",
                    comment: "VoiceOver announcement after an in-app catalog retry that did not recover."
                )
            )
            return
        }
        AccessibilityAnnouncer.layoutChanged()
        AccessibilityAnnouncer.announce(
            qfLocalized(
                "catalog.unreadable.retrySucceeded",
                defaultValue: "Account list loaded.",
                comment: "VoiceOver announcement after an in-app catalog retry that recovered."
            )
        )
    }
}
