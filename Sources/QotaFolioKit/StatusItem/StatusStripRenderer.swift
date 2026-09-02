import AppKit
import CoreGraphics
import Foundation

import QotaFolioCore

/// Turns the strip's cells into the picture the menu bar holds.
///
/// The image is drawn into its own `CGContext` at scale 2 and wrapped in an `NSImage`, not
/// hosted from SwiftUI. Two reasons, both measured on this Mac: SwiftUI compositing modifiers
/// made status-item images disappear outright on macOS 26.4, and the strip is a line drawing
/// with Apple's own control points in it — a canvas is the shortest path from those numbers to
/// those pixels.
///
/// The image is NOT a template. A template image is tinted by the system, and the tint would
/// take away the green, amber and red the whole strip exists to show. macOS adds its own soft
/// shadow to a non-template image, exactly as it does to its own items.
@MainActor public final class StatusStripRenderer {
    public static let maximumCachedImageCount = 32

    /// Every input the picture depends on. Two renders with the same key are the same
    /// picture, so the cache is exact rather than approximate.
    struct Key: Hashable {
        let cells: [BatteryCell]
        let appearance: MenuBarAppearance
        let increaseContrast: Bool
        let differentiateWithoutColor: Bool
        /// Which quantity the batteries are drawn to. Two modes over the same cells are two
        /// different pictures, so the choice belongs in the key or the cache would hand back
        /// the picture the person just switched away from.
        let shows: StripShows
    }

    private let cacheCapacity: Int
    private let options = BatteryOptions()
    private let layout = BatteryLayout()
    /// The height of the menu bar on this Mac, read once. 22 pt on macOS 26.
    private let barHeight: CGFloat
    private var cache: [Key: NSImage] = [:]
    private var leastToMostRecentlyUsedKeys: [Key] = []

    public convenience init() {
        self.init(cacheCapacity: Self.maximumCachedImageCount)
    }

    init(cacheCapacity: Int, barHeight: CGFloat = NSStatusBar.system.thickness) {
        precondition(cacheCapacity > 0)
        self.cacheCapacity = cacheCapacity
        self.barHeight = barHeight
    }

    /// The width the status item reserves for `count` batteries: the ink rounded up, plus a
    /// point of air on each side.
    ///
    /// An empty strip still reserves one battery's width. The item has to stay on the bar
    /// and stay clickable while the app has nothing to report, so it draws one empty
    /// outline instead of vanishing.
    public nonisolated static func itemLength(cellCount: Int) -> CGFloat {
        ceil(batteryStripInkWidth(count: max(1, cellCount))) + 2
    }

    public func image(
        for cells: [BatteryCell],
        appearance: MenuBarAppearance,
        increaseContrast: Bool,
        differentiateWithoutColor: Bool,
        showing: StripShows
    ) -> NSImage {
        let key = Key(
            cells: cells,
            appearance: appearance,
            increaseContrast: increaseContrast,
            differentiateWithoutColor: differentiateWithoutColor,
            shows: showing
        )
        if let cached = cachedImage(for: key) { return cached }

        let image = render(key)
        insert(image, for: key)
        return image
    }

    public func invalidate() {
        cache.removeAll(keepingCapacity: true)
        leastToMostRecentlyUsedKeys.removeAll(keepingCapacity: true)
    }

    var cachedImageCount: Int { cache.count }

    // MARK: - Drawing

    private func render(_ key: Key) -> NSImage {
        var options = options
        options.mono = key.differentiateWithoutColor
        options.shows = key.shows
        let theme = BatteryTheme.make(
            darkBar: key.appearance == .darkAqua,
            contrast: key.increaseContrast
        )
        let size = NSSize(
            width: Self.itemLength(cellCount: key.cells.count),
            height: barHeight
        )
        let scale = 2.0

        guard let ctx = CGContext(
            data: nil,
            width: Int((size.width * scale).rounded()),
            height: Int((size.height * scale).rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            let empty = NSImage(size: size)
            empty.isTemplate = false
            return empty
        }

        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        let ink = batteryStripInkWidth(count: max(1, key.cells.count), options, layout)
        let x0 = ((size.width - ink) / 2).rounded()
        let midY = size.height / 2

        if key.cells.isEmpty {
            // Nothing to report: the outline alone, at the weight an account that is not
            // answering is drawn in. The two strings say why.
            let y = (midY - options.body.h / 2).rounded()
            drawAppleBody(
                ctx,
                options.body,
                origin: CGPoint(x: x0, y: y),
                ink: batteryFade(theme.ink, theme.dim)
            )
        } else {
            drawStrip(ctx, key.cells, at: x0, midY: midY, theme, options, layout)
        }

        guard let cgImage = ctx.makeImage() else {
            let empty = NSImage(size: size)
            empty.isTemplate = false
            return empty
        }
        let image = NSImage(cgImage: cgImage, size: size)
        image.isTemplate = false
        return image
    }

    // MARK: - Cache

    private func cachedImage(for key: Key) -> NSImage? {
        guard let image = cache[key] else { return nil }
        markMostRecentlyUsed(key)
        return image
    }

    private func insert(_ image: NSImage, for key: Key) {
        cache[key] = image
        markMostRecentlyUsed(key)

        while cache.count > cacheCapacity {
            let evicted = leastToMostRecentlyUsedKeys.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private func markMostRecentlyUsed(_ key: Key) {
        if let existing = leastToMostRecentlyUsedKeys.firstIndex(of: key) {
            leastToMostRecentlyUsedKeys.remove(at: existing)
        }
        leastToMostRecentlyUsedKeys.append(key)
    }
}
