import Foundation
import Observation
import SwiftUI
import QotaFolioCore

/// Which alerts a person wants: all of them by default, and none for an account they have
/// switched off. Persisted in the app's own defaults domain.
@MainActor @Observable public final class AlertPreferences {
    private var enabled: Bool
    public private(set) var mutedAccountIDs: Set<AccountID>

    @ObservationIgnored private let defaults: UserDefaults

    public static let enabledKey = "settings.alerts.enabled.v1"
    public static let mutedAccountIDsKey = "settings.alerts.mutedAccountIDs.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        mutedAccountIDs = Set(
            (defaults.stringArray(forKey: Self.mutedAccountIDsKey) ?? []).compactMap { raw in
                UUID(uuidString: raw).map { AccountID(rawValue: $0) }
            }
        )
    }

    /// The master switch.
    public var isEnabled: Bool {
        get { enabled }
        set {
            guard newValue != enabled else { return }
            enabled = newValue
            defaults.set(newValue, forKey: Self.enabledKey)
        }
    }

    /// Whether alerts about this account are wanted: the master switch and the account's own.
    public func isEnabled(for accountID: AccountID) -> Bool {
        enabled && !mutedAccountIDs.contains(accountID)
    }

    public func setEnabled(_ wanted: Bool, for accountID: AccountID) {
        var next = mutedAccountIDs
        if wanted { next.remove(accountID) } else { next.insert(accountID) }
        guard next != mutedAccountIDs else { return }
        mutedAccountIDs = next
        defaults.set(next.map { $0.rawValue.uuidString.lowercased() }.sorted(), forKey: Self.mutedAccountIDsKey)
    }

    public func enabledBinding() -> Binding<Bool> {
        Binding(get: { self.isEnabled }, set: { self.isEnabled = $0 })
    }

    public func enabledBinding(for accountID: AccountID) -> Binding<Bool> {
        Binding(
            get: { !self.mutedAccountIDs.contains(accountID) },
            set: { self.setEnabled($0, for: accountID) }
        )
    }
}
