import Foundation
import Observation
import SwiftUI
import QotaFolioCore
import QotaFolioKit

@MainActor @Observable public final class FixtureSettingsUpdater: SettingsUpdating {
    public var updateCheckAvailability: UpdateCheckAvailability
    public private(set) var automaticallyChecksForUpdates: Bool
    public private(set) var automaticallyDownloadsUpdates: Bool

    /// Counts every call the view makes, including one it should not have made.
    ///
    /// The fixture deliberately does not refuse a check it is not ready for. Refusing here
    /// would hide a view that offers a button it should have withheld, and the view is what
    /// this fixture exists to measure.
    @ObservationIgnored public private(set) var checkCallCount = 0

    public init(
        updateCheckAvailability: UpdateCheckAvailability = .ready,
        automaticallyChecksForUpdates: Bool = true,
        automaticallyDownloadsUpdates: Bool = false
    ) {
        self.updateCheckAvailability = updateCheckAvailability
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
    }

    public func checksBinding() -> Binding<Bool> {
        Binding(
            get: { self.automaticallyChecksForUpdates },
            set: { self.automaticallyChecksForUpdates = $0 }
        )
    }

    public func downloadsBinding() -> Binding<Bool> {
        Binding(
            get: { self.automaticallyDownloadsUpdates },
            set: { self.automaticallyDownloadsUpdates = $0 }
        )
    }

    public func checkForUpdates() {
        checkCallCount += 1
    }
}

@MainActor @Observable public final class FixtureLoginAtStartupController: LoginAtStartupControlling {
    public var status: LoginAtStartupStatus
    public var failureMessage: String?
    @ObservationIgnored public private(set) var openSettingsCallCount = 0

    public init(
        status: LoginAtStartupStatus = .disabled,
        failureMessage: String? = nil
    ) {
        self.status = status
        self.failureMessage = failureMessage
    }

    public func enabledBinding() -> Binding<Bool> {
        Binding(
            get: { self.status == .enabled },
            set: { enabled in
                self.failureMessage = nil
                self.status = enabled ? .enabled : .disabled
            }
        )
    }

    public func refresh() {}

    public func openLoginItemsSettings() {
        openSettingsCallCount += 1
    }
}

@MainActor @Observable public final class FixtureAccountVisibilityController: AccountVisibilityControlling {
    public private(set) var hiddenAccountIDs: Set<AccountID>

    public init(hiddenAccountIDs: Set<AccountID> = []) {
        self.hiddenAccountIDs = hiddenAccountIDs
    }

    public func isVisible(_ accountID: AccountID) -> Bool {
        !hiddenAccountIDs.contains(accountID)
    }

    public func setVisible(_ visible: Bool, for accountID: AccountID) {
        if visible {
            hiddenAccountIDs.remove(accountID)
        } else {
            hiddenAccountIDs.insert(accountID)
        }
    }

    public func visibilityBinding(for accountID: AccountID) -> Binding<Bool> {
        Binding(
            get: { self.isVisible(accountID) },
            set: { self.setVisible($0, for: accountID) }
        )
    }
}

@MainActor @Observable public final class FixtureUninstallPresenter: UninstallPresenting {
    public var state: UninstallPresentationState
    @ObservationIgnored public private(set) var intents: [Intent] = []

    public init(state: UninstallPresentationState = .idle) {
        self.state = state
    }

    public func requestConfirmation() {
        intents.append(.requestConfirmation)
        state = .confirmation
    }

    public func cancelConfirmation() {
        intents.append(.cancelConfirmation)
        state = .idle
    }

    public func confirmRemoval() {
        intents.append(.confirmRemoval)
        state = .removing
    }

    public func showApplicationInFinder() {
        intents.append(.showInFinder)
    }

    public func quitAfterRemoval() {
        intents.append(.quitAfterRemoval)
    }

    public nonisolated enum Intent: Equatable, Sendable {
        case requestConfirmation
        case cancelConfirmation
        case confirmRemoval
        case showInFinder
        case quitAfterRemoval
    }
}
