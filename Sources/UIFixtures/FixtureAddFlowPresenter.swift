import Foundation
import Observation
import QotaFolioCore

@MainActor @Observable public final class FixtureAddFlowPresenter: AddFlowPresenting {
    public private(set) var activeFlow: AccountFlowPhase?
    public private(set) var activeFlowProvider: AccountProvider?
    public private(set) var pendingConnectedAnnouncement: AccountID?
    public private(set) var addFlowRefusal: AddFlowRefusal?

    /// What `removeAccount` answers. nil is the ordinary case: the removal was accepted.
    @ObservationIgnored public var removalRefusal: AccountRemovalRefusal?

    /// What a Continue on the naming step answers. nil is the ordinary case: the flow started.
    ///
    /// A refusal makes the fixture behave the way the coordinator does — the naming step stays on
    /// screen with the name the user typed still in it, and the reason is on the step — instead of
    /// pretending every submission starts a flow.
    @ObservationIgnored public var addSubmissionRefusal: AddFlowRefusal?

    /// What `beginReauth` answers. nil is the ordinary case: the sign-in started.
    ///
    /// A refusal also stops the fixture pretending: the flow does not move to `.starting`, which
    /// is exactly what the coordinator does when a guard refuses.
    @ObservationIgnored public var reconnectRefusal: AccountReconnectRefusal?
    @ObservationIgnored public private(set) var intents: [Intent] = []
    @ObservationIgnored private let providersByAccount: [AccountID: AccountProvider]

    public init(
        activeFlow: AccountFlowPhase? = nil,
        activeFlowProvider: AccountProvider? = nil,
        pendingConnectedAnnouncement: AccountID? = nil,
        providersByAccount: [AccountID: AccountProvider] = [:]
    ) {
        self.activeFlow = activeFlow
        self.activeFlowProvider = activeFlowProvider
        self.pendingConnectedAnnouncement = pendingConnectedAnnouncement
        self.providersByAccount = providersByAccount
    }

    public func consumeConnectedAnnouncement() -> AccountID? {
        defer { pendingConnectedAnnouncement = nil }
        return pendingConnectedAnnouncement
    }

    public func beginAddFlow() {
        intents.append(.beginAdd)
        activeFlowProvider = nil
        activeFlow = .naming
        addFlowRefusal = nil
    }

    public func submitAdd(name: String, provider: AccountProvider) -> AddFlowRefusal? {
        intents.append(.submitAdd(name: name, provider: provider))
        if let addSubmissionRefusal {
            activeFlowProvider = nil
            activeFlow = .naming
            addFlowRefusal = addSubmissionRefusal
            return addSubmissionRefusal
        }
        activeFlowProvider = provider
        activeFlow = .starting
        addFlowRefusal = nil
        return nil
    }

    public func beginReauth(_ id: AccountID) -> AccountReconnectRefusal? {
        intents.append(.beginReauth(id))
        if let reconnectRefusal { return reconnectRefusal }
        activeFlowProvider = providersByAccount[id]
        activeFlow = .starting
        return nil
    }

    public func cancelActiveFlow(_ reason: FlowDismissalReason) {
        intents.append(.cancel(reason))
        activeFlow = nil
        activeFlowProvider = nil
    }

    public func acknowledgeFailure() {
        intents.append(.acknowledgeFailure)
        if case .some(.failed) = activeFlow {
            activeFlow = nil
            activeFlowProvider = nil
        }
    }

    public func retryActiveFlow() {
        intents.append(.retry)
        activeFlow = .starting
    }

    public func requestNewDeviceCode() {
        intents.append(.requestNewDeviceCode)
        activeFlow = .starting
        activeFlowProvider = .openai
    }

    public func reopenAuthorizationBrowser() {
        intents.append(.reopenAuthorizationBrowser)
    }

    public func removeAccount(_ id: AccountID) -> AccountRemovalRefusal? {
        intents.append(.removeAccount(id))
        return removalRefusal
    }

    public nonisolated enum Intent: Equatable, Sendable {
        case beginAdd
        case submitAdd(name: String, provider: AccountProvider)
        case beginReauth(AccountID)
        case cancel(FlowDismissalReason)
        case acknowledgeFailure
        case retry
        case requestNewDeviceCode
        case reopenAuthorizationBrowser
        case removeAccount(AccountID)
    }
}
