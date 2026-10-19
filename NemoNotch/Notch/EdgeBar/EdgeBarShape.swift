import SwiftUI

/// The edge bar's body: docked to the screen's left edge, flaring **outward**
/// at both ends. The flare is an INVERSE curve — the body widens as it
/// approaches the edge and ends tangent to the bezel, so it reads as growing
/// out of the screen rather than stuck onto it (the same trick as the
/// hardware notch). The control point of each end curve sits on the edge
/// corner: that wraps the curve around the edge and carves the gap inward.
///
/// Fills its rect (x == 0 is the screen edge), so animating the frame
/// animates the body — opening is the frame's width growing.
struct EdgeBarShape: Shape {
    /// Inner corner radius (the side away from the edge).
    var corner: CGFloat = EdgeBarMetrics.corner
    /// The inverse curve radius at the ends: the body gets shorter by this
    /// much and the reach at the edge gets longer by the same.
    var flare: CGFloat = EdgeBarMetrics.flare
    /// Filling needs the segment along the edge; stroking must not have it
    /// (a hairline on the outermost pixel column). Stroke `outline`.
    var closed: Bool = true

    var outline: EdgeBarShape {
        EdgeBarShape(corner: corner, flare: flare, closed: false)
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let f = min(flare, h / 2)
        let c = max(0, min(corner, (h - 2 * f) / 2, w - f))
        let top = f
        let bottom = h - f

        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: f, y: top), control: CGPoint(x: 0, y: top))
        p.addLine(to: CGPoint(x: w - c, y: top))
        p.addQuadCurve(to: CGPoint(x: w, y: top + c), control: CGPoint(x: w, y: top))
        p.addLine(to: CGPoint(x: w, y: bottom - c))
        p.addQuadCurve(to: CGPoint(x: w - c, y: bottom), control: CGPoint(x: w, y: bottom))
        p.addLine(to: CGPoint(x: f, y: bottom))
        p.addQuadCurve(to: CGPoint(x: 0, y: h), control: CGPoint(x: 0, y: bottom))
        if closed {
            p.closeSubpath()
        }
        return p.offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
