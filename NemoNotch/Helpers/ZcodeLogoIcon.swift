import SwiftUI

/// zcode's brand "Z" mark, redrawn as a tintable vector (source: zcode.z.ai
/// icon.svg, viewBox 30×30 — the three white glyph shapes only, background
/// square dropped so it tints like a badge glyph). Mirrors `OpencodeLogoIcon`'s
/// `size`/`color` API so it drops into the same badge / source-icon slots.
struct ZcodeLogoIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = .white) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Canvas { ctx, canvas in
            // Glyph bbox in the 30 viewBox: x 5.7…24.3, y 7.1…22.91.
            // Fit the full 30×30 viewBox into the frame (uniform scale).
            let scale = min(canvas.width, canvas.height) / 30.0
            let xInset = (canvas.width - 30 * scale) / 2
            let yInset = (canvas.height - 30 * scale) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scale + xInset, y: y * scale + yInset)
            }
            func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
                var path = Path()
                guard let first = pts.first else { return path }
                path.move(to: p(first.0, first.1))
                for pt in pts.dropFirst() {
                    path.addLine(to: p(pt.0, pt.1))
                }
                path.closeSubpath()
                return path
            }

            // Top bar
            ctx.fill(
                poly([(15.47, 7.1), (14.17, 8.95), (13.27, 9.42), (6.17, 9.42), (6.17, 7.1)]),
                with: .color(color)
            )
            // Diagonal
            ctx.fill(
                poly([(24.3, 7.1), (13.14, 22.91), (5.7, 22.91), (16.86, 7.1)]),
                with: .color(color)
            )
            // Bottom bar
            ctx.fill(
                poly([(14.53, 22.91), (15.84, 21.05), (16.74, 20.58), (23.83, 20.58), (23.83, 22.91)]),
                with: .color(color)
            )
        }
        .frame(width: size, height: size)
    }
}
