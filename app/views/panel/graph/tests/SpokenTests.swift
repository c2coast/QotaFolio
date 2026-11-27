import Accessibility
import Foundation
import Graph
import Kit
import Testing

/// What the graph says to a person who cannot see it, read from the chart descriptor's data, at
/// the moment after Tuesday's banked resets, in UTC, at the panel's size.
@Suite("What the graph says aloud")
struct SpokenTests {
    static let picture = try! Record.picture("after-banked-reset")
    static let spoken = SpokenGraph(picture: picture, words: TimeWords(calendar: Record.calendar, now: picture.now.at),
                                    size: CGSize(width: 360, height: 146))

    @Test("The graph is one element: its name is the caption's, its value the forecast's sentence, then the record's")
    func element() {
        #expect(Self.spoken.name == "Points used this week, to Wed 21:00")
        #expect(Self.spoken.value == "At the last three hours’ pace, the week reaches its limit around Wed 19:15, 1h 45m before it resets.")
        #expect(Self.spoken.record == "A full banked reset at Tue 20:13 gave back 98 points.")
    }

    /// The week starts a week before its reset, Wed 12 Nov at 21:00. From the poll of Fri 14 Nov at
    /// 01:05 the week read 100 percent until the poll after the Fable reset, Tue 18 Nov at 14:11, and
    /// that stretch is the fold: a place inside it says the stretch, not a time the strip cannot place.
    @Test("The time axis says clock times, and a stretch inside a fold")
    func timeAxis() throws {
        let descriptor = Self.spoken.makeChartDescriptor()
        let axis = try #require(descriptor.xAxis as? AXNumericDataAxisDescriptor)
        #expect(axis.valueDescriptionProvider(0) == "Wed 21:00")
        #expect(axis.valueDescriptionProvider(360) == "Wed 21:00")
        let fold = try #require(try CeilingTests.ceiling("after-banked-reset").axis.pieces.first { $0.fold != nil })
        #expect(axis.valueDescriptionProvider((fold.x0 + fold.x1) / 2) == "Fri 01:05 to Tue 14:11")
    }

    @Test("The audio graph has each limit's use, its limit and its forecast, and the record's sentence")
    func series() {
        let descriptor = Self.spoken.makeChartDescriptor()
        #expect(descriptor.title == Self.spoken.name)
        #expect(descriptor.summary == "A full banked reset at Tue 20:13 gave back 98 points.")
        #expect(descriptor.series.map(\.name) == ["Weekly use", "Weekly limit", "Weekly forecast", "Fable use", "Fable limit"])
        #expect(descriptor.series.allSatisfy { $0.dataPoints.count >= 2 })
        #expect(descriptor.yAxis?.valueDescriptionProvider(100) == "100 points")
    }
}
