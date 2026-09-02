import Foundation
import QotaFolioCore

public nonisolated struct FixtureUIScenario: Sendable {
    public let accounts: [AccountConfig]
    public let snapshots: [AccountID: UsageSnapshot]
    public let pollStatus: [AccountID: AccountPollStatus]
    public let loadState: CatalogLoadState
    public let recoveryAdvisory: CatalogRecoveryAdvisory?
    public let activeFlow: AccountFlowPhase?
    public let activeFlowProvider: AccountProvider?
    public let now: Date
    /// A week of polls behind the accounts, when the scenario has one: what the panel's
    /// instrument draws and what the brain assessed from it.
    public let history: FixtureFleetHistory?

    public init(
        accounts: [AccountConfig],
        snapshots: [AccountID: UsageSnapshot],
        pollStatus: [AccountID: AccountPollStatus],
        loadState: CatalogLoadState,
        recoveryAdvisory: CatalogRecoveryAdvisory?,
        activeFlow: AccountFlowPhase?,
        activeFlowProvider: AccountProvider?,
        now: Date,
        history: FixtureFleetHistory? = nil
    ) {
        self.accounts = accounts
        self.snapshots = snapshots
        self.pollStatus = pollStatus
        self.loadState = loadState
        self.recoveryAdvisory = recoveryAdvisory
        self.activeFlow = activeFlow
        self.activeFlowProvider = activeFlowProvider
        self.now = now
        self.history = history
    }
}

public nonisolated enum FixtureUIScenarios {
    public static let now = Date(timeIntervalSince1970: 1_788_192_000)

    /// The scenario a launch asked for by name, or nil for a name this app has no fixture for.
    public static func named(_ name: String, now: Date = .now) -> FixtureUIScenario? {
        switch name {
        case "face": return panelFace(now: now)
        case "states": return panelStates(now: now)
        case "new-account": return panelNewAccount(now: now)
        case "mixed": return mixedFiveAccounts()
        case "device-code": return addFlowDeviceCode()
        case "recovery": return catalogRecovery()
        case "empty":
            return FixtureUIScenario(
                accounts: [], snapshots: [:], pollStatus: [:], loadState: .loaded,
                recoveryAdvisory: nil, activeFlow: nil, activeFlowProvider: nil, now: now
            )
        case "first-run":
            return FixtureUIScenario(
                accounts: [], snapshots: [:], pollStatus: [:], loadState: .loaded,
                recoveryAdvisory: nil, activeFlow: .naming, activeFlowProvider: nil, now: now
            )
        default: return nil
        }
    }

    /// A fleet at the product's ceiling with an awkward account in every seat, including the one
    /// the menu-bar battery cannot draw and can only say: `Personal Claude` has spent its session
    /// over a week that is still seventy per cent full. Drawn to the session it is the red
    /// hairline; drawn to the week it is a healthy green bar; and in both modes the tooltip,
    /// VoiceOver and the card say spent. That is the trade-off of drawing the week, and this is
    /// where it is photographed.
    public static func mixedFiveAccounts() -> FixtureUIScenario {
        let accounts = [
            account(index: 1, name: "Personal Claude", provider: .anthropic),
            account(index: 2, name: "Work ChatGPT", provider: .openai),
            account(index: 3, name: "Research Claude", provider: .anthropic),
            account(index: 4, name: "Family ChatGPT", provider: .openai),
            account(index: 5, name: "Archive Claude", provider: .anthropic),
        ]
        let snapshots: [AccountID: UsageSnapshot] = [
            accounts[0].id: anthropicSnapshot(sessionUsed: 100, weeklyUsed: 30, fableUsed: 94),
            accounts[1].id: openAISnapshot(used: 37.2),
            accounts[2].id: anthropicSnapshot(sessionUsed: 5, weeklyUsed: 22, fableUsed: nil),
            accounts[3].id: openAISnapshot(used: 99.1),
            accounts[4].id: anthropicSnapshot(sessionUsed: 48, weeklyUsed: 53, fableUsed: 61),
        ]
        let statuses: [AccountID: AccountPollStatus] = [
            accounts[0].id: status(.current),
            accounts[1].id: status(.stale(.invalidPayload)),
            accounts[2].id: status(.current),
            accounts[3].id: status(.suspendedForReauthentication),
            accounts[4].id: status(.configurationFailure),
        ]
        return FixtureUIScenario(
            accounts: accounts,
            snapshots: snapshots,
            pollStatus: statuses,
            loadState: .loaded,
            recoveryAdvisory: nil,
            activeFlow: nil,
            activeFlowProvider: nil,
            now: now
        )
    }

    public static func addFlowDeviceCode() -> FixtureUIScenario {
        FixtureUIScenario(
            accounts: [],
            snapshots: [:],
            pollStatus: [:],
            loadState: .loaded,
            recoveryAdvisory: nil,
            activeFlow: .openAIAwaitingDevice(
                userCode: "ABCD-EFGH",
                verificationURL: URL(string: "https://auth.openai.com/codex/device")!,
                expiresAt: now.addingTimeInterval(900)
            ),
            activeFlowProvider: .openai,
            now: now
        )
    }

    public static func catalogRecovery() -> FixtureUIScenario {
        FixtureUIScenario(
            accounts: [],
            snapshots: [:],
            pollStatus: [:],
            loadState: .missing,
            recoveryAdvisory: .credentialsWithoutCatalog(count: 2),
            activeFlow: nil,
            activeFlowProvider: nil,
            now: now
        )
    }

    private static func account(
        index: Int,
        name: String,
        provider: AccountProvider
    ) -> AccountConfig {
        let id = AccountID(
            rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
        )
        return AccountConfig(
            id: id,
            name: name,
            provider: provider,
            credentialReference: CredentialReference(accountID: id),
            displayOrder: index - 1,
            authorizationState: index == 4
                ? .needsReauthentication(failedRevision: nil)
                : .connected
        )
    }

    private static func status(_ phase: AccountPollPhase) -> AccountPollStatus {
        AccountPollStatus(
            phase: phase,
            isRefreshing: false,
            lastAttemptAt: now,
            lastSuccessAt: now.addingTimeInterval(-120),
            nextAttemptAt: now.addingTimeInterval(180)
        )
    }

    private static func openAISnapshot(used: Double) -> UsageSnapshot {
        UsageSnapshot(
            provider: .openai,
            session: nil,
            weekly: UsageWindow(
                usedPercent: used,
                resetsAt: now.addingTimeInterval(604_800),
                severity: nil
            ),
            fable: nil,
            fetchedAt: now.addingTimeInterval(-120)
        )
    }

    private static func anthropicSnapshot(
        sessionUsed: Double,
        weeklyUsed: Double,
        fableUsed: Double?
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: .anthropic,
            session: UsageWindow(
                usedPercent: sessionUsed,
                resetsAt: now.addingTimeInterval(10_800),
                severity: nil
            ),
            weekly: UsageWindow(
                usedPercent: weeklyUsed,
                resetsAt: now.addingTimeInterval(345_600),
                severity: nil
            ),
            fable: fableUsed.map {
                UsageWindow(
                    usedPercent: $0,
                    resetsAt: now.addingTimeInterval(432_000),
                    severity: $0 >= 90 ? .critical : nil
                )
            },
            fetchedAt: now.addingTimeInterval(-120)
        )
    }
}
