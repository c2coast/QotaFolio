import Foundation
import Graph
import ImageIO
import Kit
import SwiftUI
import UniformTypeIdentifiers

/// `--draw`: the graph's part of the card at one moment, written to a PNG with no window. It is
/// the caption, the Ceiling chart and the two sentences, on the card's plate over a flat stand-in
/// for the panel's glass, which a picture with no window cannot draw. Scale 2.
extension ForecastTool {
    struct Look {
        var appearance = Appearance(dark: false)
        var twelveHour = false
    }

    /// Draws each account's week at the moment, prints its sentences and the file's path.
    static func draw(_ moment: (at: Date, label: String?, account: String?), named text: String, _ forecasts: [Forecast],
                     look: Look, out: String?) throws {
        let pictures = forecasts.compactMap { $0.picture(at: moment.at) }
        guard !pictures.isEmpty else { fail("no poll at or before \(day(moment.at, .current))\n") }
        if out != nil && pictures.count > 1 { fail("--out names one file. Choose the account with --account.\n") }
        let calendar = calendar(.current)
        let stem = moment.label == nil ? text.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: ":", with: "") : text
        let words = TimeWords(calendar: calendar, twelveHour: look.twelveHour)
        for picture in pictures {
            let sentences = picture.sentences(in: words)
            let name = stem + (pictures.count > 1 ? "-\(picture.account.rawValue)" : "") + (look.appearance.dark ? "-dark" : "-light")
            let file = out.map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory.appending(path: "forecast").appending(path: "\(name).png")
            try MainActor.assumeIsolated {
                try write(picture, words: words, look.appearance, to: file)
            }
            print(sentences.forecast)
            if let record = sentences.record { print(record) }
            print(file.path)
        }
    }

    @MainActor static func write(_ picture: WeekPicture, words: TimeWords, _ appearance: Appearance, to file: URL) throws {
        let palette = Palette(appearance)
        let edge = palette.plateEdge
        let plate = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let card = WeekGraph(picture: picture, words: words, palette: palette)
            .padding(12)
            .background(plate.fill(Color(palette.plate)))
            .overlay(plate.strokeBorder(LinearGradient(colors: [Color(edge.top), Color(edge.bottom)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .padding(12)
            .background(Color(palette.standIn))
            .environment(\.colorScheme, appearance.dark ? .dark : .light)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        guard let image = renderer.cgImage else { fail("the picture did not render\n") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            fail("cannot write \(file.path)\n")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { fail("cannot write \(file.path)\n") }
    }
}
