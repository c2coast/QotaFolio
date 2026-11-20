import Foundation

/// How much of a limit is used, from 0 to 100.
///
/// A percent is made only where data enters, so code inside cannot hold 140 percent. A value
/// outside 0...100, or one that is not a number, makes no percent.
public struct Percent: Hashable, Comparable, Sendable {
    public let value: Double

    public init?(_ value: Double) {
        guard value >= 0, value <= 100 else { return nil }
        self.value = value
    }

    /// From hundredths of a percent, as version 1.0.0 stores it: 6700 is 67 percent.
    public init?(basisPoints: Int) {
        self.init(Double(basisPoints) / 100)
    }

    public static func < (a: Percent, b: Percent) -> Bool { a.value < b.value }
}
