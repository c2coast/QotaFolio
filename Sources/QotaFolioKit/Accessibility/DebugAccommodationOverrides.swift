#if DEBUG
import SwiftUI

/// The accommodation forms a debug build can be launched in, without changing this Mac.
///
/// `QOTAFOLIO_UI_ACCOMMODATIONS=increase-contrast,differentiate-without-color,largest-text,reduce-transparency,reduce-motion`.
/// Each name is one System Settings switch, and setting one here turns it on for this
/// process only — the settings themselves are never touched. That is how the menu-bar strip
/// and the panel are photographed in every form on the machine they are built on.
public nonisolated struct DebugAccommodations: Sendable {
    private let values: Set<String>

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        values = Set(
            environment["QOTAFOLIO_UI_ACCOMMODATIONS", default: ""]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
    }

    public var increaseContrast: Bool { values.contains("increase-contrast") }
    public var differentiateWithoutColor: Bool { values.contains("differentiate-without-color") }
    public var largestText: Bool { values.contains("largest-text") }
    public var reduceTransparency: Bool { values.contains("reduce-transparency") }
    public var reduceMotion: Bool { values.contains("reduce-motion") }
}

public struct DebugAccommodationOverrides: ViewModifier {
    private let accommodations: DebugAccommodations

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        accommodations = DebugAccommodations(environment: environment)
    }

    public func body(content: Content) -> some View {
        content
            .environment(
                \.dynamicTypeSize,
                accommodations.largestText ? .accessibility5 : .large
            )
            // The system's own accommodation values, forced on for this process. Liquid Glass and
            // the standard materials read these — the glass goes opaque under Reduce Transparency
            // and the panel's own tones deepen under Increase Contrast — so the forms the lab
            // captured are the forms the app draws.
            .transformEnvironment(\._colorSchemeContrast) { if accommodations.increaseContrast { $0 = .increased } }
            .transformEnvironment(\._accessibilityReduceTransparency) { if accommodations.reduceTransparency { $0 = true } }
            .transformEnvironment(\._accessibilityReduceMotion) { if accommodations.reduceMotion { $0 = true } }
    }
}
#endif
