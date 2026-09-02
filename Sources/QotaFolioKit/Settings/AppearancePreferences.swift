import AppKit
import Foundation
import Observation
import SwiftUI
import QotaFolioCore

/// What QotaFolio's own windows are painted in.
public enum QotaFolioAppearance: String, CaseIterable, Sendable {
    /// Whatever this Mac is set to, and it follows the Mac live — including the automatic switch
    /// at sunset.
    case system
    case light
    case dark

    /// The AppKit appearance to wear, or nil to wear the Mac's.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Which appearance a person wants QotaFolio's windows in: the Mac's by default. Persisted in the
/// app's own defaults domain, beside the alert preferences and the account visibility.
///
/// The windows, and not the application. Setting `NSApp.appearance` would take the menu-bar
/// batteries with it, and those are not a window of ours: they are drawn into the menu bar, whose
/// ink follows the wallpaper and can be light over a dark desktop. A battery that ignored the bar
/// it sits in would be unreadable there. So the choice reaches the panel and the Settings window,
/// each of which sets it on itself, and the strip goes on reading the bar.
@MainActor @Observable public final class AppearancePreferences {
    public static let key = "settings.general.appearance.v1"

    private var selection: QotaFolioAppearance
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: Self.key)
            .flatMap(QotaFolioAppearance.init(rawValue:)) ?? .system
    }

    public var appearance: QotaFolioAppearance {
        get { selection }
        set {
            guard newValue != selection else { return }
            selection = newValue
            defaults.set(newValue.rawValue, forKey: Self.key)
        }
    }

    /// What a window should wear right now, or nil for the Mac's own.
    public var nsAppearance: NSAppearance? { selection.nsAppearance }

    public func binding() -> Binding<QotaFolioAppearance> {
        Binding(get: { self.appearance }, set: { self.appearance = $0 })
    }
}
