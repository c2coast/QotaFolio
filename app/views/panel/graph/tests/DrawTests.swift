import Graph
import Kit
import SwiftUI
import Testing

/// The graph's part of the card draws to an image in the test runner, with no window, as
/// `tools/forecast --draw` writes it.
@Suite("The graph draws with no window")
struct DrawTests {
    @Test("The card's graph at after-banked-reset draws to an image of the panel's width, with ink in it")
    @MainActor
    func draws() throws {
        let picture = try Record.picture("after-banked-reset")
        let graph = WeekGraph(picture: picture, words: TimeWords(calendar: Record.calendar, now: picture.now.at), palette: Palette(Appearance(dark: false)))
        let renderer = ImageRenderer(content: graph)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)

        // The chart is the panel's width. The caption over it and the sentences under it, each 10
        // points away, add at least a line of 11-point type each to its height.
        #expect(image.width == Int(2 * CeilingChart.size.width))
        #expect(image.height >= Int(2 * (CeilingChart.size.height + 2 * 10 + 2 * 11)))

        // The card has no plate of its own, so every pixel with colour is ink the graph drew.
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes in
            CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                .map { context in context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) } != nil
        }
        #expect(drawn)
        let inked = stride(from: 3, to: pixels.count, by: 4).count { pixels[$0] > 0 }
        #expect(inked > width * height / 20, "\(inked) of \(width * height) pixels have colour")
    }
}
