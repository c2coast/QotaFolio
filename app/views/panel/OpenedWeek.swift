import Graph
import Kit
import SwiftUI

/// What a tapped card shows of its account's week: the Ceiling graph with its two sentences under it,
/// on the panel's glass, in the look macOS reports. Once the week has reset with nothing read since,
/// there is no picture, and the sentences stand alone.
struct OpenedWeek: View {
    let week: AccountNow.Week
    let words: TimeWords

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let palette = Palette(Appearance(dark: scheme == .dark, increasedContrast: contrast == .increased,
                                         reduceTransparency: reduceTransparency))
        if let picture = week.picture {
            WeekGraph(picture: picture, words: words, palette: palette)
        } else {
            WeekSentences(sentences: week.sentences, palette: palette)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension TimeWords {
    /// The words of the panel at a moment, on the clock the person's locale keeps.
    init(locale: Locale, timeZone: TimeZone, now: Date) {
        let hours = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        self.init(timeZone: timeZone, twelveHour: hours.contains("a"), now: now)
    }
}
