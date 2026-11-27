import Kit
import Testing

struct DesignTests {
    /// A share used turns to a whole share left, floor(100 - used), as every surface works it out.
    /// The steps change at 49 to 50 and at 79 to 80 percent used.
    @Test(arguments: [(0.0, Level.plenty), (49, .plenty), (49.5, .low), (50, .low), (79, .low), (79.5, .nearlyGone), (80, .nearlyGone), (100, .nearlyGone)])
    func theStepOfAShareUsed(used: Double, step: Level) {
        #expect(Level(remainingPercent: Int((100 - used).rounded(.down))) == step)
    }

    /// A look picks its own form, and Reduce Transparency picks the opaque one.
    @Test func aLookPicksItsForm() {
        let glass = Looks<Colour>(light: .white(0.1), lightIncreased: .white(0.2), dark: .white(0.3), darkIncreased: .white(0.4))
        let opaque = Looks<Colour>(light: .ink(0.5), lightIncreased: .ink(0.6), dark: .ink(0.7), darkIncreased: .ink(0.8))
        let value = Translucent(glass: glass, opaque: opaque)
        #expect(value(dark: false, increased: false, reduceTransparency: false) == .white(0.1))
        #expect(value(dark: false, increased: true, reduceTransparency: false) == .white(0.2))
        #expect(value(dark: true, increased: false, reduceTransparency: false) == .white(0.3))
        #expect(value(dark: true, increased: true, reduceTransparency: false) == .white(0.4))
        #expect(value(dark: false, increased: false, reduceTransparency: true) == .ink(0.5))
        #expect(value(dark: true, increased: true, reduceTransparency: true) == .ink(0.8))
    }

    /// A colour's parts, as the strip and the graph draw it. The look's own ink is black on light and
    /// white on dark.
    @Test func aColoursParts() {
        #expect(Colour.srgb(0x39955E).parts(dark: false) == (57.0 / 255, 149.0 / 255, 94.0 / 255, 1))
        #expect(Colour.ink(0.07).parts(dark: false) == (0, 0, 0, 0.07))
        #expect(Colour.ink(0.07).parts(dark: true) == (1, 1, 1, 0.07))
        #expect(Colour.white(0.4).parts(dark: false) == (1, 1, 1, 0.4))
        #expect(Colour.black(0.4).parts(dark: true) == (0, 0, 0, 0.4))
        #expect(Colour.grey(0.92, weight: 0.52).parts(dark: true) == (0.92, 0.92, 0.92, 0.52))
    }
}
