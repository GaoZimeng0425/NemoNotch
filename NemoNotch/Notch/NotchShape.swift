import SwiftUI

/// The notch shell silhouette, drawn as one path — the single source of truth
/// every notch-surface consumer (shell fill/clip, activity glow, transient
/// capsule) shares. boring.notch-style topology: the top edge spans the
/// rect's full width (blending into the menu bar next to the physical
/// notch), then concave flares curve inward — one quad curve per top corner —
/// into the body, whose sides sit `topCornerRadius` in from the rect's sides;
/// the bottom corners round out convexly.
///
/// Callers size the frame to `bodyWidth + topCornerRadius * 2`: the body is
/// the panel/badge content width, the flares extend past it at the top.
///
/// Replaces the pre-path construction where the silhouette was an emergent
/// property of rectangles + `clipShape` + `destinationOut` corner overlays
/// with ±0.5pt seam patches, duplicated across the shell mask, the glow ring
/// and the capsule.
struct NotchShape: Shape {
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat

    /// Both radii animate across open/close (6/8 closed → 19/24 opened).
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topCornerRadius, bottomCornerRadius) }
        set {
            topCornerRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }

        let topR = min(topCornerRadius, rect.width / 2)
        let bottomR = min(bottomCornerRadius, (rect.width - 2 * topR) / 2, rect.height / 2)

        var path = Path()
        // Full-width top edge ends at the top-left flare, which curves
        // concavely down into the body's left side.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topR, y: rect.minY + topR),
            control: CGPoint(x: rect.minX + topR, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + topR, y: rect.maxY - bottomR))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topR + bottomR, y: rect.maxY),
            control: CGPoint(x: rect.minX + topR, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topR - bottomR, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topR, y: rect.maxY - bottomR),
            control: CGPoint(x: rect.maxX - topR, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - topR, y: rect.minY + topR))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topR, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
