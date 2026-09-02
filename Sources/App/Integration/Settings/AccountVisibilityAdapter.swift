import Foundation
import Observation
import SwiftUI
import QotaFolioCore
import QotaFolioKit

@MainActor
protocol AccountVisibilityPreferenceStoring: AnyObject {
    func loadHiddenAccountIDs() -> Set<AccountID>
    func saveHiddenAccountIDs(_ accountIDs: Set<AccountID>)
}

@MainActor
final class UserDefaultsAccountVisibilityPreferenceStore: AccountVisibilityPreferenceStoring {
    static let defaultKey = "settings.accountVisibility.hiddenAccountIDs.v1"

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = UserDefaultsAccountVisibilityPreferenceStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func loadHiddenAccountIDs() -> Set<AccountID> {
        Set(
            (defaults.stringArray(forKey: key) ?? []).compactMap { rawValue in
                UUID(uuidString: rawValue).map { AccountID(rawValue: $0) }
            }
        )
    }

    func saveHiddenAccountIDs(_ accountIDs: Set<AccountID>) {
        defaults.set(
            accountIDs
                .map { $0.rawValue.uuidString.lowercased() }
                .sorted(),
            forKey: key
        )
    }
}

@MainActor
protocol AccountVisibilityProjecting: AccountVisibilityControlling {
    func visibleAccounts(from accounts: [AccountConfig]) -> [AccountConfig]
}

@MainActor @Observable
final class PersistedAccountVisibilityController: AccountVisibilityProjecting {
    private(set) var hiddenAccountIDs: Set<AccountID>

    @ObservationIgnored private let catalog: any AccountCataloging
    @ObservationIgnored private let preferences: any AccountVisibilityPreferenceStoring
    @ObservationIgnored private var observationIsCancelled = false

    init(
        catalog: any AccountCataloging,
        preferences: any AccountVisibilityPreferenceStoring
    ) {
        self.catalog = catalog
        self.preferences = preferences
        hiddenAccountIDs = preferences.loadHiddenAccountIDs()
        reconcileWithCatalog()
        persist()
        armCatalogObservation()
    }

    convenience init(
        catalog: any AccountCataloging,
        defaults: UserDefaults = .standard
    ) {
        self.init(
            catalog: catalog,
            preferences: UserDefaultsAccountVisibilityPreferenceStore(defaults: defaults)
        )
    }

    func isVisible(_ accountID: AccountID) -> Bool {
        !hiddenAccountIDs.contains(accountID)
    }

    func setVisible(_ visible: Bool, for accountID: AccountID) {
        _ = applyVisibility(visible, for: accountID)
    }

    /// Applies a visibility change, or answers why it was refused.
    ///
    /// Deliberately not `@discardableResult`. A caller that drops the answer refuses the last
    /// visible account by returning: the binding reads the unchanged value back, and the switch
    /// animates itself on again with nothing said. Settings asks `accountVisibilityRefusal` before
    /// it draws, so the refused switch arrives dimmed and carrying its reason; this is the same
    /// rule enforced where the write happens.
    func applyVisibility(
        _ visible: Bool,
        for accountID: AccountID
    ) -> AccountVisibilityRefusal? {
        reconcileWithCatalog()

        let orderedAccountIDs = catalog.accounts.map(\.id)
        // An account the catalog does not list has no switch in Settings and no row anywhere
        // else, so there is no control to explain a refusal to. There is simply nothing to do.
        guard orderedAccountIDs.contains(accountID) else { return nil }

        var next = hiddenAccountIDs
        if visible {
            next.remove(accountID)
        } else {
            if let refusal = accountVisibilityRefusal(
                hiding: accountID,
                visibleAccountIDs: Set(orderedAccountIDs).subtracting(next)
            ) {
                return refusal
            }
            next.insert(accountID)
        }
        commit(next)
        return nil
    }

    func visibilityBinding(for accountID: AccountID) -> Binding<Bool> {
        Binding(
            get: { self.isVisible(accountID) },
            set: { self.setVisible($0, for: accountID) }
        )
    }

    func visibleAccounts(from accounts: [AccountConfig]) -> [AccountConfig] {
        accounts.filter { isVisible($0.id) }
    }

    func cancelObservation() {
        observationIsCancelled = true
    }

    private func armCatalogObservation() {
        guard !observationIsCancelled else { return }

        withObservationTracking {
            _ = catalog.loadState
            _ = catalog.accounts.map(\.id)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.observationIsCancelled else { return }
                self.reconcileWithCatalog()
                self.armCatalogObservation()
            }
        }
    }

    /// Repairs the stored preference against the catalog the app actually has.
    ///
    /// The force-unhide below is the same invariant `applyVisibility` refuses on, enforced from
    /// the other side, and it is correct. Removing an account can empty the visible set without
    /// anybody hiding anything: hide A while B is visible, then remove B. Left alone, the panel
    /// and the status strip would have nothing to show and the only way back would be a Settings
    /// switch the user cannot find a reason to look for. The first account in display order is
    /// the one restored, because that is the row at the top of the user's own list.
    ///
    /// It stays silent, and that is also correct: nothing the user just did was refused. The
    /// Settings footer states the rule, so the account that comes back is not unexplained.
    private func reconcileWithCatalog() {
        guard catalog.loadState == .loaded else { return }

        let orderedAccountIDs = catalog.accounts.map(\.id)
        let currentAccountIDs = Set(orderedAccountIDs)
        var next = hiddenAccountIDs.intersection(currentAccountIDs)

        if !orderedAccountIDs.isEmpty, next.count == orderedAccountIDs.count {
            next.remove(orderedAccountIDs[0])
        }

        commit(next)
    }

    private func commit(_ next: Set<AccountID>) {
        guard next != hiddenAccountIDs else { return }
        hiddenAccountIDs = next
        persist()
    }

    private func persist() {
        preferences.saveHiddenAccountIDs(hiddenAccountIDs)
    }
}
