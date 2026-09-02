import AppKit
import SwiftUI
import QotaFolioCore

public struct DeviceCodeStep: View {
    public let userCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    public let requestNewCode: () -> Void
    public let cancel: () -> Void

    /// Not "is the panel open". This step is rendered on two surfaces — the panel and the Settings
    /// sheet — and the panel's answer is wrong on the other one, where it freezes this countdown.
    @Environment(\.surfaceIsOnScreen) private var surfaceIsOnScreen

    public init(
        userCode: String,
        verificationURL: URL,
        expiresAt: Date,
        requestNewCode: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) {
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresAt = expiresAt
        self.requestNewCode = requestNewCode
        self.cancel = cancel
    }

    public var body: some View {
        Group {
            if surfaceIsOnScreen {
                TimelineView(.explicit(secondsUntilExpiry)) { context in
                    content(now: context.date)
                }
            } else {
                content(now: .now)
            }
        }
    }

    /// One tick a second up to the expiry the provider set, and then no more.
    ///
    /// A periodic schedule never ends, so a periodic countdown would keep waking the process
    /// every second after the code expired — redrawing the same "Code expired" for as long as the
    /// surface stayed open, which on the Settings sheet is until the user dismisses it. The
    /// sequence is lazy and unfolds from `expiresAt` itself; nothing is stored and nothing is
    /// converted, so the schedule is as absolute as the deadline it counts to.
    ///
    /// It runs one entry past expiry on purpose. `ExplicitTimelineSchedule` does not render its
    /// LAST entry — it uses it as the end of the one before, which was measured rather than
    /// assumed — so a sequence that stopped at expiry would never draw the
    /// expired state, and a user would read "Code expires in 0m 0s" until they gave up. The
    /// trailing entry is that terminator, and an already-expired code still gets its one render.
    private var secondsUntilExpiry: UnfoldFirstSequence<Date> {
        let expiresAt = expiresAt
        var drewExpiredState = false
        return sequence(first: Date.now) { previous in
            guard !drewExpiredState else { return nil }
            drewExpiredState = previous >= expiresAt
            return previous.addingTimeInterval(1)
        }
    }

    private func content(now: Date) -> some View {
        let expired = now >= expiresAt
        let remaining = max(0, Int(ceil(expiresAt.timeIntervalSince(now))))

        return VStack(alignment: .leading, spacing: 16) {
            Text(qfLocalized("auth.heading.signIn.chatGPT", defaultValue: "Sign in to ChatGPT", comment: "Heading for the ChatGPT device-code sign-in flow."))
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AXIdentifiers.authHeading)

            if expired {
                Label(
                    qfLocalized("auth.chatgpt.expired", defaultValue: "Code expired", comment: "The ChatGPT device code is no longer valid."),
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.headline)
                .foregroundStyle(.orange)

                Text(qfLocalized(
                    "auth.chatgpt.expired.body",
                    defaultValue: "Get a new code to continue. The ChatGPT authorization page remains the correct page.",
                    comment: "Instructions after a ChatGPT device code expires."
                ))
                .foregroundStyle(.secondary)
            } else {
                Text(qfLocalized(
                    "auth.chatgpt.instructions",
                    defaultValue: "Open the page below and enter this code:",
                    comment: "Instructions for the active ChatGPT device-code flow."
                ))
                .font(.body)
                .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Text(userCode)
                        .font(.system(.title2, design: .monospaced, weight: .semibold))
                        .textSelection(.enabled)
                        .accessibilityLabel(qfLocalized("auth.chatgpt.code.label", defaultValue: "ChatGPT device code", comment: "VoiceOver label for the exact ChatGPT device code."))
                        .accessibilityValue(spokenCode)
                        .accessibilityIdentifier(AXIdentifiers.chatGPTCode)

                    Spacer()

                    Button {
                        copy(userCode, concealed: true)
                        AccessibilityAnnouncer.announce(
                            qfLocalized("announce.codeCopied", defaultValue: "Code copied", comment: "VoiceOver announcement after copying a device code.")
                        )
                    } label: {
                        Label(
                            qfLocalized("auth.chatgpt.copyCode", defaultValue: "Copy code", comment: "Copy the exact ChatGPT device code."),
                            systemImage: "doc.on.doc"
                        )
                    }
                    .frame(minWidth: 40, minHeight: 40)
                    .accessibilityIdentifier(AXIdentifiers.chatGPTCopyCode)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(verificationURL.absoluteString)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        openPageButton.fixedSize()
                        copyAddressButton.fixedSize()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        openPageButton
                        copyAddressButton
                    }
                }
            }

            Text(expired ? "" : expirationText(remaining))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier(AXIdentifiers.chatGPTStatus)
                .accessibilityHidden(expired)

            HStack {
                Button(
                    qfLocalized("action.cancel", defaultValue: "Cancel", comment: "Cancel an in-progress operation."),
                    action: cancel
                )
                .keyboardShortcut(.cancelAction)
                .frame(minWidth: 40, minHeight: 40)

                Spacer()

                if expired {
                    Button(action: requestNewCode) {
                        Label(
                            qfLocalized("auth.chatgpt.getNewCode", defaultValue: "Get a new code", comment: "Request a fresh ChatGPT device code."),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 40, minHeight: 40)
                    .accessibilityIdentifier(AXIdentifiers.chatGPTGetNewCode)
                }
            }
        }
    }

    private var openPageButton: some View {
        Button {
            NSWorkspace.shared.open(verificationURL)
        } label: {
            Label(
                qfLocalized("auth.chatgpt.openPage", defaultValue: "Open ChatGPT authorization page", comment: "Open the ChatGPT device authorization page."),
                systemImage: "arrow.up.forward.app"
            )
        }
        .buttonStyle(.borderedProminent)
        .frame(minWidth: 40, minHeight: 40)
        .accessibilityIdentifier(AXIdentifiers.chatGPTOpenVerification)
    }

    private var copyAddressButton: some View {
        Button {
            copy(verificationURL.absoluteString)
            AccessibilityAnnouncer.announce(
                qfLocalized("announce.addressCopied", defaultValue: "Web address copied", comment: "VoiceOver announcement after copying the device authorization URL.")
            )
        } label: {
            Label(
                qfLocalized("auth.chatgpt.copyAddress", defaultValue: "Copy web address", comment: "Copy the ChatGPT device authorization URL."),
                systemImage: "link"
            )
        }
        .frame(minWidth: 40, minHeight: 40)
        .accessibilityIdentifier(AXIdentifiers.chatGPTCopyVerificationURL)
    }

    /// The code spelled out, from the one derivation the arrival announcement also reads.
    ///
    /// Written here and only here, it could differ from the sentence a user hears when this step
    /// arrives.
    private var spokenCode: String {
        spokenDeviceCode(userCode)
    }

    private func expirationText(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return qfLocalized(
            "auth.chatgpt.expires",
            defaultValue: "Code expires in \(minutes)m \(remainder)s",
            comment: "Visible countdown for the active ChatGPT device code. Never announce every tick."
        )
    }

    /// Puts a value on the general pasteboard, optionally marked as one that must not travel.
    ///
    /// `NSPasteboard.general` is read by clipboard-history utilities and synced to the user's
    /// other Apple devices by Universal Clipboard — a route out of the machine that the
    /// endpoint guard has no view of at all. The device code is the one credential-adjacent
    /// value this product displays on purpose, so the copy of it
    /// inherits that care: `org.nspasteboard.ConcealedType` is the community convention that
    /// clipboard managers and the sync path honour, and it is declared before the string so it
    /// is already on the item when the first reader sees it.
    ///
    /// The verification URL is public and is copied without the mark.
    private func copy(_ value: String, concealed: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if concealed {
            pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        }
        pasteboard.setString(value, forType: .string)
    }
}
