import Foundation

public enum Colour: Hashable, Sendable {
    /// An opaque sRGB colour, `0xRRGGBB`.
    case srgb(UInt32)
    /// Black at a weight from 0 to 1.
    case black(Double)
    case white(Double)
    /// The look's own ink at a weight: black on light, white on dark.
    case ink(Double)
    /// An sRGB grey, 0 black to 1 white, at a weight.
    case grey(Double, weight: Double)

    /// The colour's sRGB parts from 0 to 1, in a light or a dark look.
    public func parts(dark: Bool) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        switch self {
        case .srgb(let hex):
            (Double(hex >> 16 & 0xFF) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255, 1)
        case .black(let weight): (0, 0, 0, weight)
        case .white(let weight): (1, 1, 1, weight)
        case .ink(let weight): dark ? (1, 1, 1, weight) : (0, 0, 0, weight)
        case .grey(let grey, let weight): (grey, grey, grey, weight)
        }
    }
}

/// A value in each of the four looks: light or dark, plain or with Increase Contrast.
public struct Looks<Value: Hashable & Sendable>: Hashable, Sendable {
    public let light, lightIncreased, dark, darkIncreased: Value

    public init(light: Value, lightIncreased: Value, dark: Value, darkIncreased: Value) {
        (self.light, self.lightIncreased, self.dark, self.darkIncreased) = (light, lightIncreased, dark, darkIncreased)
    }

    public func callAsFunction(dark: Bool, increased: Bool) -> Value {
        switch (dark, increased) {
        case (false, false): self.light
        case (false, true): self.lightIncreased
        case (true, false): self.dark
        case (true, true): self.darkIncreased
        }
    }
}

/// A value on the glass in each look, and its form under Reduce Transparency, when the glass is
/// opaque.
public struct Translucent<Value: Hashable & Sendable>: Hashable, Sendable {
    public let glass, opaque: Looks<Value>

    public init(glass: Looks<Value>, opaque: Looks<Value>) {
        (self.glass, self.opaque) = (glass, opaque)
    }

    public func callAsFunction(dark: Bool, increased: Bool, reduceTransparency: Bool) -> Value {
        (reduceTransparency ? opaque : glass)(dark: dark, increased: increased)
    }
}

/// A role in the type scale: the system font at a size in points and a weight, and whether its
/// digits are of one width.
public struct TypeRole: Hashable, Sendable {
    public enum Weight: Hashable, Sendable { case regular, medium, semibold }

    public let size: Double
    public let weight: Weight
    public let monospacedDigits: Bool

    public init(size: Double, weight: Weight, monospacedDigits: Bool) {
        (self.size, self.weight, self.monospacedDigits) = (size, weight, monospacedDigits)
    }
}

/// A motion's timing: a curve and its duration in seconds.
public struct Timing: Hashable, Sendable {
    public enum Curve: Hashable, Sendable {
        /// A spring with no bounce.
        case smooth
        case easeOut, easeInOut
    }

    public let curve: Curve
    public let duration: Double

    public init(curve: Curve, duration: Double) {
        (self.curve, self.duration) = (curve, duration)
    }
}

public enum Level: Hashable, Sendable, CaseIterable {
    case plenty, low, nearlyGone

    /// The step of a whole share left, 0 to 100.
    public init(remainingPercent: Int) {
        self = remainingPercent <= Tokens.Level.nearlyGoneAtOrBelow ? .nearlyGone
            : remainingPercent > Tokens.Level.plentyAbove ? .plenty : .low
    }

    /// The step of a share used: the whole share left is what remains, rounded down. The card, the
    /// menu bar, the graph and what each says aloud all take a limit's level here.
    public init(used: Double) {
        self.init(remainingPercent: Int(min(100, max(0, 100 - used)).rounded(.down)))
    }

    public var colour: Looks<Colour> {
        switch self {
        case .plenty: Tokens.Level.plenty
        case .low: Tokens.Level.low
        case .nearlyGone: Tokens.Level.nearlyGone
        }
    }
}
