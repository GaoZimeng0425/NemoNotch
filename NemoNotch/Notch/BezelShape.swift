import SwiftUI

/// The one silhouette every bezel-docked surface draws — the notch shell
/// (shell fill/clip, activity glow, transient capsule) and the docked AI
/// bar. A body that grows OUT of a screen edge:
///
/// - the segment along the docked edge spans the rect's full length;
/// - at both ends an INVERSE curve (`flare`) bends from the edge into the
///   body — its control point sits on the edge line, so the curve wraps the
///   bezel and the gap is carved inward (read: grows out of the screen, not
///   stuck onto it; the hardware notch's own trick);
/// - the body's far corners round convexly (`corner`).
///
/// The body is `flare` shorter than the rect at each end; callers size the
/// frame to `bodyLength + 2 × flare` along the edge.
///
/// One path, drawn canonically for the TOP edge; `.leading` is its transpose
/// (x ↔ y) and `.trailing` that mirrored, so the side bars and the notch can
/// never drift apart in topology.
/// Both radii animate, so open/close morphs (notch 6/8 → 19/24).
struct BezelShape: Shape {
    enum Edge {
        case top, leading, trailing
    }

    var edge: Edge = .top
    /// The inverse curve at both ends of the edge.
    var flare: CGFloat
    /// The body's far corners (away from the edge).
    var corner: CGFloat
    /// Filling needs the segment along the edge; stroking must not have it
    /// (a hairline on the screen's outermost pixels). Stroke `outline`.
    var closed: Bool = true

    var outline: BezelShape {
        BezelShape(edge: edge, flare: flare, corner: corner, closed: false)
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, corner) }
        set {
            flare = newValue.first
            corner = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        switch edge {
        case .top:
            return Self.canonical(length: rect.width, depth: rect.height, flare: flare, corner: corner, closed: closed)
                .offsetBy(dx: rect.minX, dy: rect.minY)
        case .leading:
            // Transpose: the canonical top edge (y == 0) lands on x == 0.
            let transpose = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: rect.minX, ty: rect.minY)
            return Self.canonical(length: rect.height, depth: rect.width, flare: flare, corner: corner, closed: closed)
                .applying(transpose)
        case .trailing:
            // Transposed and mirrored: the canonical top edge lands on x == maxX.
            let mirror = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: rect.maxX, ty: rect.minY)
            return Self.canonical(length: rect.height, depth: rect.width, flare: flare, corner: corner, closed: closed)
                .applying(mirror)
        }
    }

    /// The top-edge path in a `length × depth` rect at the origin.
    private static func canonical(
        length w: CGFloat,
        depth h: CGFloat,
        flare: CGFloat,
        corner: CGFloat,
        closed: Bool
    ) -> Path {
        let f = max(0, min(flare, w / 2))
        let c = max(0, min(corner, (w - 2 * f) / 2, h / 2))

        var path = Path()
        // From the edge's start, the flare curves inward into the body side.
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: f, y: f), control: CGPoint(x: f, y: 0))
        path.addLine(to: CGPoint(x: f, y: h - c))
        path.addQuadCurve(to: CGPoint(x: f + c, y: h), control: CGPoint(x: f, y: h))
        path.addLine(to: CGPoint(x: w - f - c, y: h))
        path.addQuadCurve(to: CGPoint(x: w - f, y: h - c), control: CGPoint(x: w - f, y: h))
        path.addLine(to: CGPoint(x: w - f, y: f))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - f, y: 0))
        if closed {
            path.closeSubpath()
        }
        return path
    }
}
