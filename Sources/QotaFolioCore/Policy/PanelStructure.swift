import Foundation

public nonisolated enum PanelFlowStep: Hashable, Sendable, CaseIterable {
    case naming
    case anthropicBrowser
    case deviceCode
    case progress
    case failure

    public init?(_ phase: AccountFlowPhase?) {
        switch renderableFlow(phase) {
        case nil:
            return nil
        case .naming?:
            self = .naming
        case .anthropicWaitingInBrowser?:
            self = .anthropicBrowser
        case .openAIAwaitingDevice?:
            self = .deviceCode
        case .starting?, .exchanging?, .storing?:
            self = .progress
        case .failed?:
            self = .failure
        case .connected?:
            return nil
        }
    }
}

/// Which account prompt the panel is showing, at the grain the panel's height depends on.
///
/// The panel re-reads its own height when `PanelStructure` changes, so a prompt that is not in
/// this value opens without the panel noticing it has grown. `isRefused` is here for the same
/// reason and no other: a refusal adds a sentence, a sentence adds height. The draft name a user
/// is typing is deliberately absent — the prompts reserve their caption slot, so typing changes
/// no height and has nothing to report.
public nonisolated enum AccountPromptStep: Hashable, Sendable {
    case rename(isRefused: Bool)
    case remove(isRefused: Bool)
}

/// The discrete facts the open panel re-measures itself on: which body it shows, which accounts
/// it lists, which add-flow step or prompt is up.
///
/// The cards are deliberately not in this value. A card's height follows its content — how many
/// windows the provider reports, which state line it shows, whether its instrument is open — and
/// the card list measures that content itself and asks the panel to re-measure when it changes
/// (`AccountListView`). Describing the card's shape here as well would be a second derivation of
/// the same height, and two derivations of one height can disagree.
public nonisolated struct PanelStructure: Equatable, Sendable {
    public let loadState: CatalogLoadState
    public let accountIDs: [AccountID]
    public let hasAdvisory: Bool
    public let flowStep: PanelFlowStep?
    public let promptStep: AccountPromptStep?

    public init(
        loadState: CatalogLoadState,
        accountIDs: [AccountID],
        hasAdvisory: Bool,
        flowStep: PanelFlowStep?,
        promptStep: AccountPromptStep?
    ) {
        self.loadState = loadState
        self.accountIDs = accountIDs
        self.hasAdvisory = hasAdvisory
        self.flowStep = flowStep
        self.promptStep = promptStep
    }
}
