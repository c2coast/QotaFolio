import Charts
import SwiftUI
import QotaFolioCore

/// What unfolds beneath a card's rows when it is clicked open: the window in hand as a stepped
/// line with the projection continued as information, the week's completed five-hour windows as
/// blocks, and the account's own numbers. Informational voice only — nothing here tells the
/// person what to do.
struct AccountInstrument: View {
    let account: AccountConfig
    let face: AccountFace
    let snapshot: UsageSnapshot?
    let assessment: AccountAssessment?
    let store: any AccountsStoring
    let tone: PanelTone

    @State private var trace: AccountUsageTrace?
    /// The point under the cursor on the chart.
    @State private var scrub: Date?

    @Environment(\.panelNow) private var panelNow
    @Environment(\.sentenceStyle) private var style
    @Environment(\.colorSchemeContrast) private var contrast

    private var now: Date { panelNow ?? .now }

    /// The window the chart draws: the account's session, or the first window it has.
    private var level: UsageWindowLevel? { face.session ?? face.windows.first }
    private var forecast: WindowForecast? {
        guard let level else { return nil }
        return assessment?.windows.first { $0.windowKey == level.id }
    }
    private var windowTrace: UsageWindowTrace? {
        guard let level else { return nil }
        return trace?.window(level.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let level, let windowTrace {
                chartHeader(level, windowTrace)
                chart(level, windowTrace)
                Text(forecast.map { InstrumentSentences.landing($0, now: now, style: style) } ?? InstrumentSentences.noProjection())
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().opacity(0.6)
            week
            Divider().opacity(0.6)
            planLine
        }
        .padding(.top, 2)
        .task(id: traceKey) {
            trace = await store.trace(for: account.id)
        }
    }

    /// Re-read the history when a new poll lands, so the line grows with the day.
    private var traceKey: String {
        "\(account.id.rawValue.uuidString)/\(snapshot?.fetchedAt.timeIntervalSinceReferenceDate ?? 0)"
    }

    // MARK: (a) The window in hand

    private struct Sample: Identifiable {
        let at: Date
        let usedPercent: Double
        var id: Date { at }
    }

    private func occurrenceStart(_ windowTrace: UsageWindowTrace) -> Date {
        forecast?.occurrenceOpenedAt ?? windowTrace.currentOccurrence.openedAt
    }

    private func samples(_ windowTrace: UsageWindowTrace) -> [Sample] {
        let start = occurrenceStart(windowTrace)
        return windowTrace.samples
            .filter { $0.at >= start && $0.at <= now }
            .map { Sample(at: $0.at, usedPercent: $0.usedPercent) }
    }

    private func chartHeader(_ level: UsageWindowLevel, _ windowTrace: UsageWindowTrace) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(InstrumentSentences.chartTitle(windowTitle: level.title, since: occurrenceStart(windowTrace), style: style))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            if let readout = readout(samples(windowTrace)) {
                Text(readout)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
        }
    }

    /// The sample under the cursor and the step that brought it there.
    private func readout(_ samples: [Sample]) -> String? {
        guard let scrub, let index = nearestSample(samples, to: scrub) else { return nil }
        let sample = samples[index]
        let previous = index > 0 ? (at: samples[index - 1].at, usedPercent: samples[index - 1].usedPercent) : nil
        return InstrumentSentences.readout(at: sample.at, usedPercent: sample.usedPercent, previous: previous, style: style)
    }

    private func nearestSample(_ samples: [Sample], to date: Date) -> Int? {
        guard !samples.isEmpty else { return nil }
        return samples.indices.min {
            abs(samples[$0].at.timeIntervalSince(date)) < abs(samples[$1].at.timeIntervalSince(date))
        }
    }

    private func chart(_ level: UsageWindowLevel, _ windowTrace: UsageWindowTrace) -> some View {
        let samples = samples(windowTrace)
        // The window itself wears the colour of the row's bar directly above it: this chart is
        // that row opened up, and it says the same thing about the same window. A forecast may
        // not have formed yet — on a new account it has not — but the level always has.
        let hue = tone.level(level.usedPercent)
        // Where the window is going, which is a different question and gets the verdict's own
        // tone. Only ever drawn under `projecting`, which a silent forecast never is.
        let ahead = forecast.map { tone.verdict($0.verdict) } ?? hue
        let start = occurrenceStart(windowTrace)
        let reset = forecast?.resetsAt ?? windowTrace.currentOccurrence.resetsAt ?? level.resetsAt ?? now
        let end = max(reset.addingTimeInterval(8 * 60), start.addingTimeInterval(30 * 60))
        let band = forecast?.outerBand
        let projecting = forecast.map { !$0.verdict.isSilent && $0.landingPercent != nil } ?? false

        return Chart {
            // The band, opening forward: the further ahead, the less is known.
            if projecting, let band, let forecast {
                AreaMark(
                    x: .value("Time", now),
                    yStart: .value("Low", forecast.usedPercent),
                    yEnd: .value("High", forecast.usedPercent),
                    series: .value("Series", "band")
                )
                .foregroundStyle(ahead.opacity(tone.range))
                .interpolationMethod(.linear)
                AreaMark(
                    x: .value("Time", reset),
                    yStart: .value("Low", band.lowPercent),
                    yEnd: .value("High", band.highPercent),
                    series: .value("Series", "band")
                )
                .foregroundStyle(ahead.opacity(tone.range))
                .interpolationMethod(.linear)
            }

            // The samples: a staircase, because that is what a window is.
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Time", sample.at),
                    y: .value("Used", sample.usedPercent),
                    series: .value("Series", "actual")
                )
                .interpolationMethod(.stepEnd)
                .foregroundStyle(hue)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            // The projection, continued to the landing — information, dashed so it reads as such.
            if projecting, let forecast, let landing = forecast.landingPercent {
                LineMark(x: .value("Time", now), y: .value("Used", forecast.usedPercent), series: .value("Series", "forecast"))
                    .foregroundStyle(ahead)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                LineMark(x: .value("Time", reset), y: .value("Used", landing), series: .value("Series", "forecast"))
                    .foregroundStyle(ahead)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
                PointMark(x: .value("Time", reset), y: .value("Used", landing))
                    .foregroundStyle(ahead)
                    .symbolSize(28)
            }

            // The reset, labelled with its clock time. The label stands well clear of the rule,
            // because a window landing near the top puts its own point exactly there.
            RuleMark(x: .value("Reset", reset))
                .foregroundStyle(tone.chartRule)
                .lineStyle(StrokeStyle(lineWidth: 1))
                .annotation(position: .leading, alignment: .top, spacing: 10) {
                    Text(PanelWords.clock(reset, style: style))
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(tone.chartInk)
                }

            // The point under the cursor.
            if let scrub, let index = nearestSample(samples, to: scrub) {
                let sample = samples[index]
                RuleMark(x: .value("Scrub", sample.at))
                    .foregroundStyle(tone.chartInk)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Scrub", sample.at), y: .value("Used", sample.usedPercent))
                    .foregroundStyle(hue)
                    .symbolSize(64)
                PointMark(x: .value("Scrub", sample.at), y: .value("Used", sample.usedPercent))
                    .foregroundStyle(tone.chartHole)
                    .symbolSize(20)
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...100)
        .chartXSelection(value: $scrub)
        // The hour labels are built rather than formatted, so they are spelled by the person's
        // own clock like every other time on the panel, and so their tone is this app's and
        // not the chart's idea of one.
        .chartXAxis {
            AxisMarks(position: .bottom, values: hourMarks(from: start, to: reset)) { mark in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(tone.chartGrid)
                AxisValueLabel {
                    if let hour = mark.as(Date.self) {
                        Text(PanelWords.clock(hour, style: style))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(tone.chartInk)
                    }
                }
            }
        }
        // The guide lines at half and full, with nothing written against them. The line's own
        // height against them is the reading, and a label beside each would only take width
        // away from the plot.
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 50, 100]) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(tone.chartGrid)
            }
        }
        .frame(height: 132)
        .accessibilityLabel(InstrumentSentences.chartTitle(windowTitle: level.title, since: start, style: style))
        .accessibilityValue(forecast.map { InstrumentSentences.landing($0, now: now, style: style) } ?? InstrumentSentences.noProjection())
    }

    /// Whole hours inside the occurrence, stopping short of the reset so its own label has the
    /// room.
    private func hourMarks(from start: Date, to end: Date) -> [Date] {
        let calendar = style.calendar
        var marks: [Date] = []
        var hour = calendar.nextDate(after: start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? start
        while hour < end.addingTimeInterval(-30 * 60), marks.count < 48 {
            marks.append(hour)
            hour = hour.addingTimeInterval(3600)
        }
        return marks
    }

    // MARK: (b) The week

    private var completed: [CompletedUsageWindow] {
        guard let windowTrace else { return [] }
        let horizon = now.addingTimeInterval(-7 * 86_400)
        return windowTrace.completed
            .filter { $0.closed >= horizon }
            .sorted { $0.openedAt < $1.openedAt }
    }

    private func isHollow(_ window: CompletedUsageWindow) -> Bool {
        window.usedPercentAtClose < BrainPolicy.ledgerActiveClosePercent
    }

    private var week: some View {
        let windows = completed
        return VStack(alignment: .leading, spacing: 8) {
            Text(InstrumentSentences.weekTitle())
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if !windows.isEmpty {
                weekRow(windows)
            }
            Text(weekSentence(windows))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The week's completed windows, grouped into the days they opened on: a wider gap between
    /// days than between the windows inside one, so the shape of the week is visible without
    /// anything being written under it.
    ///
    /// The blocks and the gaps inside a day shrink to fit the card; the gaps BETWEEN days do
    /// not. The grouping is carried by the difference between the two gaps, and a busy week —
    /// the one whose shape is most worth seeing — is exactly the week that would shrink that
    /// difference to nothing.
    private func weekRow(_ windows: [CompletedUsageWindow]) -> some View {
        let days = days(windows)
        return GeometryReader { proxy in
            let scale = WeekBlock.scale(
                blockCount: windows.count,
                dayCount: days.count,
                available: proxy.size.width
            )
            HStack(alignment: .bottom, spacing: WeekBlock.dayGap) {
                ForEach(days, id: \.first?.openedAt) { day in
                    HStack(alignment: .bottom, spacing: WeekBlock.gap * scale) {
                        ForEach(day, id: \.openedAt) { window in
                            WeekBlock(
                                usedPercentAtClose: window.usedPercentAtClose,
                                isHollow: isHollow(window),
                                scale: scale,
                                tone: tone,
                                sentence: InstrumentSentences.block(
                                    weekday: weekdayName(window.opened),
                                    openedAt: PanelWords.clock(window.opened, style: style),
                                    usedPercentAtClose: window.usedPercentAtClose,
                                    isHollow: isHollow(window)
                                )
                            )
                        }
                    }
                }
            }
        }
        .frame(height: WeekBlock.height)
    }

    /// The windows split into the days they opened on, oldest first. They arrive sorted, so a
    /// day ends where the next window's calendar day differs.
    private func days(_ windows: [CompletedUsageWindow]) -> [[CompletedUsageWindow]] {
        var days: [[CompletedUsageWindow]] = []
        for window in windows {
            if let previous = days.last?.last,
               style.calendar.isDate(previous.opened, inSameDayAs: window.opened) {
                days[days.count - 1].append(window)
            } else {
                days.append([window])
            }
        }
        return days
    }

    private func weekSentence(_ windows: [CompletedUsageWindow]) -> String {
        let worked = windows.filter { !isHollow($0) }.count
        return InstrumentSentences.week(
            worked: worked,
            untouched: windows.count - worked,
            plan: assessment?.week,
            weeklyResetsAt: face.weekly?.resetsAt,
            style: style
        )
    }

    private func weekdayName(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: style.locale, calendar: style.calendar, timeZone: style.timeZone).weekday(.abbreviated))
    }

    // MARK: (c) The account's own numbers

    private var planLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let plan = face.planName {
                Text(plan)
                    .font(.system(size: 12, weight: .medium))
                Text("·").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            Text(spendLine)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var spendLine: String {
        if let extra = snapshot?.extraUsage, extra.isEnabled, let limit = extra.monthlyLimit {
            return InstrumentSentences.extraUsage(extra, limit: limit, style: style)
        }
        if let credits = snapshot?.credits, credits.count > 0 {
            return InstrumentSentences.credits(credits, style: style)
        }
        return InstrumentSentences.noExtraUsage()
    }
}

/// One completed five-hour window: its height is what it closed at, its colour is the level it
/// closed at, and a window nobody worked in is an empty outline.
///
/// Nothing is written under it. The day, the time it opened and where it closed are in the
/// hover and in the sentence VoiceOver reads — one sentence, so the picture and the voice
/// cannot disagree.
struct WeekBlock: View {
    /// One block at full size, and the two gaps: between windows inside a day, and between
    /// days. `scale` shrinks all three together when a week has too many windows for the card.
    static let width: CGFloat = 18
    static let gap: CGFloat = 3
    static let dayGap: CGFloat = 10
    static let height: CGFloat = 30

    /// How much a row of `blockCount` windows spread over `dayCount` days has to shrink to fit
    /// `available` points. The day gaps are taken off the top and keep their full size; what is
    /// left is shared by the blocks and the gaps inside a day.
    static func scale(blockCount: Int, dayCount: Int, available: CGFloat) -> CGFloat {
        let flexible = CGFloat(blockCount) * width + CGFloat(max(0, blockCount - dayCount)) * gap
        guard flexible > 0 else { return 1 }
        let room = available - CGFloat(max(0, dayCount - 1)) * dayGap
        return min(1, max(0, room) / flexible)
    }

    let usedPercentAtClose: Double
    let isHollow: Bool
    let scale: CGFloat
    let tone: PanelTone
    let sentence: String

    var body: some View {
        Group {
            if isHollow {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        Color.primary.opacity(tone.increased ? 0.45 : 0.22),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                    )
            } else {
                // The whole window as a quiet track, with what it closed at standing in it —
                // the row's own bar language, turned on its end. Without the track a light
                // window is three points of colour floating on nothing.
                ZStack(alignment: .bottom) {
                    Rectangle().fill(tone.track)
                    UnevenRoundedRectangle(
                        topLeadingRadius: radius,
                        topTrailingRadius: radius,
                        style: .continuous
                    )
                    .fill(tone.level(usedPercentAtClose))
                    .frame(height: max(2, Self.height * min(usedPercentAtClose, 100) / 100))
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            }
        }
        .frame(width: Self.width * scale, height: Self.height)
        .help(sentence)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sentence)
        // `.help` is the hover AND the accessibility hint. The sentence is already the label,
        // and VoiceOver reading it twice is worse than not hearing it at all.
        .accessibilityHint("")
    }

    private var radius: CGFloat { max(1, 3 * scale) }
}
