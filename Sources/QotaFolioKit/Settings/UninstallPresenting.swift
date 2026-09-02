import Observation
import QotaFolioCore

/// The four things "Remove My Data" removes, so a step that did not go can be named.
///
/// Deleting the credentials is the one that matters and the one that cannot be undone.
/// The other three are tidying: a file left behind, a preference left behind, a login-item
/// registration left behind. Each is reported by name rather than folded into one word,
/// because "something went wrong" tells a user nothing they can act on.
public nonisolated enum UninstallStep: Hashable, Sendable, CaseIterable {
    case pollingStopped
    case credentialsDeleted
    case localFilesRemoved
    case openAtLoginUnregistered
}

public nonisolated enum UninstallPresentationState: Equatable, Sendable {
    case idle
    case confirmation
    case removing
    /// The removal ran. `problems` is empty when every step went.
    case finished(problems: [UninstallStep])
}

@MainActor public protocol UninstallPresenting: AnyObject, Observable {
    var state: UninstallPresentationState { get }
    func requestConfirmation()
    func cancelConfirmation()
    func confirmRemoval()
    func showApplicationInFinder()
    func quitAfterRemoval()
}
