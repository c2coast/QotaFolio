import Foundation
import Observation
import SwiftUI
import QotaFolioCore

/// Which quantity a person wants the menu-bar batteries drawn to: what this session lets them
/// spend, or what the week still holds. Persisted in the app's own defaults domain, beside the
/// appearance choice and the account visibility.
///
/// The batteries and the Control follow it; the words do not. In either mode the tooltip, what
/// VoiceOver reads, the Control's title and the panel's cards say both figures, so a battery
/// drawn to the week and an account that is spent for the next 47 minutes never read as a
/// disagreement — the picture answers one question and the words answer both.
@MainActor @Observable public final class StripPreferences {
    public static let key = "settings.general.stripShows.v1"

    private var selection: StripShows
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.key)
            .flatMap(StripShows.init(rawValue:)) ?? .session
    }

    public var shows: StripShows {
        get { selection }
        set {
            guard newValue != selection else { return }
            selection = newValue
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }

    public func binding() -> Binding<StripShows> {
        Binding(get: { self.shows }, set: { self.shows = $0 })
    }
}
