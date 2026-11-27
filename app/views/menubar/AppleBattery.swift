import CoreGraphics

// ============================================================================
// APPLE'S BATTERY, REPRODUCED.
// Control points lifted verbatim from the vector (PDF) renditions inside
// /System/Library/CoreServices/ControlCenter.app/Contents/Resources/Assets.car
// battery-outline (23x12), battery-cap (2x12), battery-small-outline (19x10).
// Apple strokes with lineWidth 2 CLIPPED to the path => a 1pt wall on the inside
// of the outer edge. We reproduce that construction exactly.
//
// Overlaid on Apple's own art at 32x supersample, this path disagrees on 0.042 %
// of the inked area — antialiasing edges only.
// ============================================================================

/// Apple's two battery sizes. The menu bar uses the small one.
nonisolated enum BatteryBody: Hashable, Sendable {
    case regular
    case small

    var w: CGFloat { self == .regular ? 23 : 19 }
    var h: CGFloat { self == .regular ? 12 : 10 }
    var capW: CGFloat { self == .regular ? 1.5 : 1.25 }
    var capH: CGFloat { self == .regular ? 4.235294 : 3.75 }
    /// Body plus cap: 24.5 pt regular, 20.25 pt small.
    var ink: CGFloat { w + capW }
}

/// Apple's outline path in its own 23x12 (or 19x10) coordinate space, origin bottom-left.
nonisolated func appleOutlinePath(_ b: BatteryBody) -> CGPath {
    let p = CGMutablePath()
    if b == .regular {
        p.move(to: CGPoint(x: 4.268869, y: 12))
        p.addLine(to: CGPoint(x: 18.73113, y: 12))
        p.addCurve(to: CGPoint(x: 21.29645, y: 11.55522), control1: CGPoint(x: 20.21551, y: 12), control2: CGPoint(x: 20.75378, y: 11.84545))
        p.addCurve(to: CGPoint(x: 22.55522, y: 10.29645), control1: CGPoint(x: 21.83911, y: 11.265), control2: CGPoint(x: 22.265, y: 10.83911))
        p.addCurve(to: CGPoint(x: 23, y: 7.731131), control1: CGPoint(x: 22.84545, y: 9.753781), control2: CGPoint(x: 23, y: 9.21551))
        p.addLine(to: CGPoint(x: 23, y: 4.268869))
        p.addCurve(to: CGPoint(x: 22.55522, y: 1.703552), control1: CGPoint(x: 23, y: 2.78449), control2: CGPoint(x: 22.84545, y: 2.246219))
        p.addCurve(to: CGPoint(x: 21.29645, y: 0.444776), control1: CGPoint(x: 22.265, y: 1.160885), control2: CGPoint(x: 21.83911, y: 0.7349973))
        p.addCurve(to: CGPoint(x: 18.73113, y: 0), control1: CGPoint(x: 20.75378, y: 0.1545546), control2: CGPoint(x: 20.21551, y: 0))
        p.addLine(to: CGPoint(x: 4.268869, y: 0))
        p.addCurve(to: CGPoint(x: 1.703552, y: 0.444776), control1: CGPoint(x: 2.78449, y: 0), control2: CGPoint(x: 2.246219, y: 0.1545546))
        p.addCurve(to: CGPoint(x: 0.444776, y: 1.703552), control1: CGPoint(x: 1.160885, y: 0.7349973), control2: CGPoint(x: 0.7349973, y: 1.160885))
        p.addCurve(to: CGPoint(x: 0, y: 4.268869), control1: CGPoint(x: 0.1545546, y: 2.246219), control2: CGPoint(x: 0, y: 2.78449))
        p.addLine(to: CGPoint(x: 0, y: 7.731131))
        p.addCurve(to: CGPoint(x: 0.444776, y: 10.29645), control1: CGPoint(x: 0, y: 9.21551), control2: CGPoint(x: 0.1545546, y: 9.753781))
        p.addCurve(to: CGPoint(x: 1.703552, y: 11.55522), control1: CGPoint(x: 0.7349973, y: 10.83911), control2: CGPoint(x: 1.160885, y: 11.265))
        p.addCurve(to: CGPoint(x: 4.268869, y: 12), control1: CGPoint(x: 2.246219, y: 11.84545), control2: CGPoint(x: 2.78449, y: 12))
    } else {
        p.move(to: CGPoint(x: 3.589439, y: 10))
        p.addLine(to: CGPoint(x: 15.41056, y: 10))
        p.addCurve(to: CGPoint(x: 17.56758, y: 9.626014), control1: CGPoint(x: 16.65869, y: 10), control2: CGPoint(x: 17.11129, y: 9.870044))
        p.addCurve(to: CGPoint(x: 18.62601, y: 8.567584), control1: CGPoint(x: 18.02388, y: 9.381984), control2: CGPoint(x: 18.38198, y: 9.02388))
        p.addCurve(to: CGPoint(x: 19, y: 6.410561), control1: CGPoint(x: 18.87004, y: 8.111288), control2: CGPoint(x: 19, y: 7.658687))
        p.addLine(to: CGPoint(x: 19, y: 3.589439))
        p.addCurve(to: CGPoint(x: 18.62601, y: 1.432416), control1: CGPoint(x: 19, y: 2.341313), control2: CGPoint(x: 18.87004, y: 1.888712))
        p.addCurve(to: CGPoint(x: 17.56758, y: 0.3739858), control1: CGPoint(x: 18.38198, y: 0.9761197), control2: CGPoint(x: 18.02388, y: 0.6180157))
        p.addCurve(to: CGPoint(x: 15.41056, y: 0), control1: CGPoint(x: 17.11129, y: 0.1299559), control2: CGPoint(x: 16.65869, y: 0))
        p.addLine(to: CGPoint(x: 3.589439, y: 0))
        p.addCurve(to: CGPoint(x: 1.432416, y: 0.3739858), control1: CGPoint(x: 2.341313, y: 0), control2: CGPoint(x: 1.888712, y: 0.1299559))
        p.addCurve(to: CGPoint(x: 0.3739858, y: 1.432416), control1: CGPoint(x: 0.9761197, y: 0.6180157), control2: CGPoint(x: 0.6180157, y: 0.9761197))
        p.addCurve(to: CGPoint(x: 0, y: 3.589439), control1: CGPoint(x: 0.1299559, y: 1.888712), control2: CGPoint(x: 0, y: 2.341313))
        p.addLine(to: CGPoint(x: 0, y: 6.410561))
        p.addCurve(to: CGPoint(x: 0.3739858, y: 8.567584), control1: CGPoint(x: 0, y: 7.658687), control2: CGPoint(x: 0.1299559, y: 8.111288))
        p.addCurve(to: CGPoint(x: 1.432416, y: 9.626014), control1: CGPoint(x: 0.6180157, y: 9.02388), control2: CGPoint(x: 0.9761197, y: 9.381984))
        p.addCurve(to: CGPoint(x: 3.589439, y: 10), control1: CGPoint(x: 1.888712, y: 9.870044), control2: CGPoint(x: 2.341313, y: 10))
    }
    p.closeSubpath()
    return p
}

/// Apple's cap ("battery-cap"): flat left edge, superelliptic bulge right. Normalised then scaled.
nonisolated func appleCapPath(_ b: BatteryBody, at x: CGFloat, midY: CGFloat) -> CGPath {
    let sx = b.capW / 1.5
    let sy = b.capH / 4.235294
    func P(_ px: CGFloat, _ py: CGFloat) -> CGPoint {
        CGPoint(x: x + px * sx, y: midY + (py - 6) * sy)
    }
    let p = CGMutablePath()
    p.move(to: P(0, 8.117647))
    p.addLine(to: P(0, 3.882353))
    p.addCurve(to: P(1.5, 6), control1: P(0.9089323, 4.241057), control2: P(1.5, 5.075506))
    p.addCurve(to: P(0, 8.117647), control1: P(1.5, 6.924494), control2: P(0.9089323, 7.758943))
    p.closeSubpath()
    return p
}

/// Draws Apple's battery body and cap, exactly as ControlCenter does it.
///
/// `origin` is the bottom-left of the BODY. Returns the total ink width.
@discardableResult
nonisolated func drawAppleBody(
    _ ctx: CGContext,
    _ b: BatteryBody,
    origin: CGPoint,
    ink: CGColor,
    wall: CGFloat = 1.0
) -> CGFloat {
    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    let path = appleOutlinePath(b)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip(using: .evenOdd)                          // Apple: W* n
    ctx.addPath(path)
    ctx.setLineWidth(wall * 2)                         // Apple: 2 w, clipped -> a 1pt wall inside
    ctx.setStrokeColor(ink)
    ctx.strokePath()
    ctx.restoreGState()
    ctx.addPath(appleCapPath(b, at: b.w, midY: b.h / 2))
    ctx.setFillColor(ink)
    ctx.fillPath()
    ctx.restoreGState()
    return b.ink
}

/// The fill box Apple leaves inside the body: wall (1pt) + gap (1pt) on every side.
///
/// Derived from SF Symbols battery.100percent @13pt — the fill sits 0.72pt (h) / 0.81pt (v)
/// inside a 0.98pt wall. On a 10pt body that lands the fill at 0.600 of the body height;
/// Apple's own is 0.583. A 2.0pt total inset also lands on whole device pixels at 2x.
nonisolated func batteryFillBox(_ b: BatteryBody, inset: CGFloat = 2.0) -> CGRect {
    CGRect(x: inset, y: inset, width: b.w - inset * 2, height: b.h - inset * 2)
}
