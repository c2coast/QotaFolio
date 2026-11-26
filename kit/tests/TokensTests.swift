import Kit
import Testing

// Every design value, in every form, as the app drew it at 17f615d. Each expected value is copied by
// hand from the file named beside it, never read from Tokens, so a value changed in
// design/tokens.json fails here until the change is meant.
struct TokensTests {
    @Test func theLevelsAndTheirRule() {
        // Sources/QotaFolioModel/Surface/LevelPalette.swift:38-41, 132-161
        #expect(Tokens.Level.plentyAbove == 50)
        #expect(Tokens.Level.nearlyGoneAtOrBelow == 20)
        #expect(Tokens.Level.plenty == Looks(light: .srgb(0x39955E), lightIncreased: .srgb(0x1E7C48), dark: .srgb(0x59D389), darkIncreased: .srgb(0x52EC93)))
        #expect(Tokens.Level.low == Looks(light: .srgb(0xA97500), lightIncreased: .srgb(0x8B6000), dark: .srgb(0xEBAA2E), darkIncreased: .srgb(0xFDBE54)))
        #expect(Tokens.Level.nearlyGone == Looks(light: .srgb(0xB0263A), lightIncreased: .srgb(0x93142B), dark: .srgb(0xF65C69), darkIncreased: .srgb(0xFB8085)))
    }

    /// A share used turns to a whole share left, floor(100 - used), as every surface works it out.
    /// The steps change at 49 to 50 and at 79 to 80 percent used.
    @Test(arguments: [(0.0, Level.plenty), (49, .plenty), (49.5, .low), (50, .low), (79, .low), (79.5, .nearlyGone), (80, .nearlyGone), (100, .nearlyGone)])
    func theStepOfAShareUsed(used: Double, step: Level) {
        #expect(Level(remainingPercent: Int((100 - used).rounded(.down))) == step)
    }

    @Test func theLevelsColourTheirSteps() {
        #expect(Level.plenty.colour == Tokens.Level.plenty)
        #expect(Level.low.colour == Tokens.Level.low)
        #expect(Level.nearlyGone.colour == Tokens.Level.nearlyGone)
    }

    @Test func theSurfaces() {
        // Sources/QotaFolioKit/Dropdown/Face/PanelTone.swift:173-175, 213-247, 94-99, 159-161
        #expect(Tokens.Surface.slabTint == Looks(light: .grey(0.92, weight: 0.52), lightIncreased: .grey(0.92, weight: 0.52), dark: .grey(0.16, weight: 0.52), darkIncreased: .grey(0.16, weight: 0.52)))
        #expect(Tokens.Surface.plateFill == Translucent(
            glass: Looks(light: .white(0.42), lightIncreased: .white(0.72), dark: .white(0.13), darkIncreased: .white(0.26)),
            opaque: Looks(light: .ink(0.07), lightIncreased: .ink(0.16), dark: .ink(0.07), darkIncreased: .ink(0.16))))
        #expect(Tokens.Surface.plateEdgeTop == Translucent(
            glass: Looks(light: .white(0.38), lightIncreased: .white(0.60), dark: .white(0.20), darkIncreased: .white(0.45)),
            opaque: Looks(light: .ink(0.16), lightIncreased: .ink(0.40), dark: .ink(0.16), darkIncreased: .ink(0.40))))
        #expect(Tokens.Surface.plateEdgeBottom == Translucent(
            glass: Looks(light: .black(0.07), lightIncreased: .black(0.18), dark: .black(0.14), darkIncreased: .black(0.30)),
            opaque: Looks(light: .ink(0.16), lightIncreased: .ink(0.40), dark: .ink(0.16), darkIncreased: .ink(0.40))))
        #expect(Tokens.Surface.plateHoverLift == Looks(light: 0.06, lightIncreased: 0.08, dark: 0.06, darkIncreased: 0.08))
        #expect(Tokens.Surface.hoverWash == Looks(light: 0.08, lightIncreased: 0.14, dark: 0.08, darkIncreased: 0.14))
        #expect(Tokens.Surface.track == Looks(light: .black(0.08), lightIncreased: .black(0.16), dark: .black(0.16), darkIncreased: .black(0.28)))
        #expect(Tokens.Surface.spent == Looks(light: 0.6, lightIncreased: 0.85, dark: 0.6, darkIncreased: 0.85))
        // app/views/panel/graph/Palette.swift:74
        #expect(Tokens.Surface.standIn == Looks(light: .srgb(0xEBEBEB), lightIncreased: .srgb(0xEBEBEB), dark: .srgb(0x292929), darkIncreased: .srgb(0x292929)))
    }

    @Test func theChartNeutrals() {
        // Sources/QotaFolioKit/Dropdown/Face/PanelTone.swift:85, 125-146
        #expect(Tokens.Chart.grid == Looks(light: .black(0.14), lightIncreased: .black(0.26), dark: .white(0.14), darkIncreased: .white(0.28)))
        #expect(Tokens.Chart.rule == Looks(light: .black(0.30), lightIncreased: .black(0.45), dark: .white(0.32), darkIncreased: .white(0.48)))
        #expect(Tokens.Chart.smallPrint == Looks(light: .black(0.62), lightIncreased: .black(0.82), dark: .white(0.72), darkIncreased: .white(0.90)))
        #expect(Tokens.Chart.hole == Looks(light: .white(0.86), lightIncreased: .white(0.92), dark: .black(0.60), darkIncreased: .black(0.72)))
        #expect(Tokens.Chart.range == Looks(light: 0.16, lightIncreased: 0.32, dark: 0.16, darkIncreased: 0.32))
        // app/views/panel/graph/Palette.swift:32-41
        #expect(Tokens.Chart.words == Looks(light: .black(0.85), lightIncreased: .black(0.95), dark: .white(0.85), darkIncreased: .white(0.95)))
        #expect(Tokens.Chart.secondaryWords == Looks(light: .black(0.60), lightIncreased: .black(0.70), dark: .white(0.62), darkIncreased: .white(0.80)))
        #expect(Tokens.Chart.ceiling == Looks(light: .black(0.48), lightIncreased: .black(0.62), dark: .white(0.46), darkIncreased: .white(0.62)))
    }

    @Test func theMenuBarStrip() {
        // Sources/QotaFolioKit/StatusItem/BatteryStrip.swift:30-37, 63-79, 152
        #expect(Tokens.MenuBar.ink == Looks(light: .black(0.90), lightIncreased: .black(1), dark: .white(1), darkIncreased: .white(1)))
        #expect(Tokens.MenuBar.dim == Looks(light: 0.55, lightIncreased: 0.80, dark: 0.55, darkIncreased: 0.80))
        #expect(Tokens.MenuBar.gap == 6)
        #expect(Tokens.MenuBar.fillInset == 2)
        #expect(Tokens.MenuBar.fillRadius == 1)
        #expect(Tokens.MenuBar.smallestFill == 1.2)
    }

    @Test func thePanelsNumbers() {
        // Sources/QotaFolioKit/Panel/PanelLayout.swift and Dropdown/Face/PanelTone.swift:8-30
        #expect(Tokens.Panel.width == 408)
        #expect(Tokens.Panel.maxHeight == 704)
        #expect(Tokens.Panel.radius == 24)
        #expect(Tokens.Panel.padding == 12)
        #expect(Tokens.Panel.cardGap == 10)
        #expect(Tokens.Panel.anchorGap == 6)
        #expect((Tokens.Panel.shadowRoomTop, Tokens.Panel.shadowRoomSide, Tokens.Panel.shadowRoomBottom) == (24, 32, 40))
        #expect(Tokens.Panel.cardPadding == 12)
        #expect(Tokens.Panel.barHeight == 6)
        #expect(Tokens.Panel.nameColumn == 64)
        #expect(Tokens.Panel.percentColumn == 38)
        #expect(Tokens.Panel.markSize == 22)
        #expect(Tokens.Panel.hitTarget == 40)
        #expect(Tokens.Panel.glyphWell == 28)
        #expect(Tokens.Panel.headerHeight == 30)
    }

    /// Each role as the call sites set it: `.system(size:weight:)`, and `.monospacedDigit()` where
    /// the line had it.
    @Test func theTypeRoles() {
        let roles: [(TypeRole, Double, TypeRole.Weight, Bool)] = [
            (Tokens.Typography.title, 13, .semibold, false), // AccountCard.swift:134
            (Tokens.Typography.label, 12, .medium, false), // WindowRow.swift:24, AccountInstrument.swift:351
            (Tokens.Typography.figure, 12, .semibold, true), // WindowRow.swift:28-29
            (Tokens.Typography.body, 12, .regular, false), // WindowRow.swift:33, AccountCard.swift:267
            (Tokens.Typography.bodyFigures, 12, .regular, true), // CeilingChart.swift:91-92, AccountInstrument.swift:355-356
            (Tokens.Typography.chartTitle, 11, .medium, false), // CeilingChart.swift:86, AccountInstrument.swift:86
            (Tokens.Typography.note, 11, .medium, true), // AccountCard.swift:147-148
            (Tokens.Typography.caption, 11, .regular, false), // AccountCard.swift:139
            (Tokens.Typography.captionFigures, 11, .regular, true), // WindowRow.swift:76-77, PanelFooterView.swift:49-50
            (Tokens.Typography.axis, 10, .regular, true), // ChartType.swift:29, AccountInstrument.swift:213-214
            (Tokens.Typography.axisMedium, 10, .medium, true), // ChartType.swift:29, AccountInstrument.swift:182-183
            (Tokens.Typography.axisStrong, 10, .semibold, true), // ChartType.swift:29
            (Tokens.Typography.glyph, 13, .medium, false), // PanelFooterView.swift:212, MoreActionsMenu.swift:119
            (Tokens.Typography.advisoryGlyph, 15, .medium, false), // MenuBarPlacementAdvisoryRow.swift:17
            (Tokens.Typography.aboutGlyph, 44, .semibold, false), // AboutView.swift:10
        ]
        for (role, size, weight, figures) in roles {
            #expect(role == TypeRole(size: size, weight: weight, monospacedDigits: figures))
        }
    }

    @Test func theMotions() {
        // Sources/QotaFolioKit/Panel/PanelMotion.swift:14-30, Dropdown/Face/PanelTone.swift:203
        #expect(Tokens.Motion.card == Timing(curve: .smooth, duration: 0.30))
        #expect(Tokens.Motion.dissolve == Timing(curve: .easeInOut, duration: 0.2))
        #expect(Tokens.Motion.hover == Timing(curve: .easeOut, duration: 0.15))
    }

    /// A look picks its own form, and Reduce Transparency picks the opaque one.
    @Test func aLookPicksItsForm() {
        let fill = Tokens.Surface.plateFill
        #expect(fill(dark: false, increased: false, reduceTransparency: false) == .white(0.42))
        #expect(fill(dark: true, increased: true, reduceTransparency: false) == .white(0.26))
        #expect(fill(dark: true, increased: true, reduceTransparency: true) == .ink(0.16))
        #expect(Tokens.Chart.grid(dark: false, increased: true) == .black(0.26))
        #expect(Tokens.Chart.grid(dark: true, increased: false) == .white(0.14))
    }

    /// A colour's parts, as the strip and the graph draw it.
    @Test func aColoursParts() {
        #expect(Colour.srgb(0x39955E).parts(dark: false) == (57.0 / 255, 149.0 / 255, 94.0 / 255, 1))
        #expect(Colour.ink(0.07).parts(dark: false) == (0, 0, 0, 0.07))
        #expect(Colour.ink(0.07).parts(dark: true) == (1, 1, 1, 0.07))
        #expect(Colour.white(0.4).parts(dark: false) == (1, 1, 1, 0.4))
        #expect(Colour.grey(0.92, weight: 0.52).parts(dark: true) == (0.92, 0.92, 0.92, 0.52))
    }
}
