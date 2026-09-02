import SwiftUI
import QotaFolioCore

/// A provider's mark, from the app's own asset catalog. It follows the panel's appearance
/// through the asset's light and dark variants. Size it with `.frame`.
///
/// Hidden from VoiceOver: the card speaks the provider's name in its one sentence.
struct ProviderMark: View {
    let provider: AccountProvider

    var body: some View {
        BrandAssetLoader.image(provider == .anthropic ? .providerMarkAnthropic : .providerMarkOpenAI)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}
