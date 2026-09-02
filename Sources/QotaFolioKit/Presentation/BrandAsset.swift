import AppKit
import SwiftUI

nonisolated enum BrandAsset: String, CaseIterable, Sendable {
    case qotaFolioGlyph = "QotaFolioGlyph"
    case providerMarkAnthropic = "ProviderMarkAnthropic"
    case providerMarkOpenAI = "ProviderMarkOpenAI"
}

@MainActor
enum BrandAssetLoader {
    private final class BundleToken: NSObject {}

    private static var resolvedBundles: [BrandAsset: Bundle] = [:]

    static func image(_ asset: BrandAsset) -> Image {
        Image(asset.rawValue, bundle: bundle(containing: asset))
    }

    static func bundle(containing asset: BrandAsset) -> Bundle {
        if let cached = resolvedBundles[asset] {
            return cached
        }

        let imageName = NSImage.Name(asset.rawValue)
        let candidates = candidateBundles()
        if let bundle = candidates.first(where: { $0.image(forResource: imageName) != nil }) {
            resolvedBundles[asset] = bundle
            return bundle
        }

        let searchedPaths = candidates
            .map(\.bundleURL.path)
            .joined(separator: "\n- ")
        fatalError(
            "Required QotaFolio brand asset '\(asset.rawValue)' is missing. Searched:\n- \(searchedPaths)"
        )
    }

    private static func candidateBundles() -> [Bundle] {
        let frameworkBundle = Bundle(for: BundleToken.self)
        var candidates: [Bundle] = []
        var seenURLs: Set<URL> = []

        func append(_ bundle: Bundle) {
            let url = bundle.bundleURL.standardizedFileURL
            guard seenURLs.insert(url).inserted else { return }
            candidates.append(bundle)
        }

        append(Bundle.main)
        append(frameworkBundle)

        var directory = frameworkBundle.bundleURL.deletingLastPathComponent()
        for _ in 0..<6 {
            if ["app", "bundle"].contains(directory.pathExtension),
               let bundle = Bundle(url: directory)
            {
                append(bundle)
            }

            let siblingAppURL = directory.appending(path: "QotaFolio.app", directoryHint: .isDirectory)
            if let bundle = Bundle(url: siblingAppURL) {
                append(bundle)
            }

            let parent = directory.deletingLastPathComponent()
            guard parent != directory else { break }
            directory = parent
        }

        Bundle.allBundles.forEach(append)
        Bundle.allFrameworks.forEach(append)
        return candidates
    }
}
