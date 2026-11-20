import Foundation

/// How the product says an amount in whole numbers, as the chart page does. The sentences and the
/// graph both round through it, so a number reads the same in the picture and under it.
public enum Whole {
    /// The whole percent a reading shows: the percent rounded down, as the page's `whole`.
    public static func percent(_ value: Double) -> Int { Int((value + 1e-9).rounded(.down)) }

    /// The whole percent a limit has left when it lands at `landing`, never below zero.
    public static func left(_ landing: Double) -> Int { max(0, 100 - percent(landing)) }

    /// Points to the nearest whole number, and at a half the one above, also below zero, as
    /// JavaScript's `Math.round`.
    public static func points(_ n: Double) -> Int {
        let down = n.rounded(.down)
        return Int(n - down >= 0.5 ? down + 1 : down)
    }
}
