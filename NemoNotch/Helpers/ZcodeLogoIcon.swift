import SwiftUI

/// zcode's brand "Z" mark, redrawn as a tintable vector (source: zcode.z.ai
/// icon.svg, viewBox 30×30 — the three white glyph shapes only, background
/// square dropped so it tints like a badge glyph). Mirrors `OpencodeLogoIcon`'s
/// `size`/`color` API so it drops into the same badge / source-icon slots.
/// Drawn as a shape, not a `Canvas` (see `OpencodeLogoIcon`).
struct ZcodeLogoIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = .white) {
        self.size = size
        self.color = color
    }

    var body: some View {
        ZcodeLogoShape()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// zcode's "Z": its three glyph shapes, in the 30 viewBox.
struct ZcodeLogoShape: Shape {
    private static let polygons: [[(CGFloat, CGFloat)]] = [
        // Top bar
        [(15.47, 7.1), (14.17, 8.95), (13.27, 9.42), (6.17, 9.42), (6.17, 7.1)],
        // Diagonal
        [(24.3, 7.1), (13.14, 22.91), (5.7, 22.91), (16.86, 7.1)],
        // Bottom bar
        [(14.53, 22.91), (15.84, 21.05), (16.74, 20.58), (23.83, 20.58), (23.83, 22.91)],
    ]

    func path(in canvas: CGRect) -> Path {
        // Glyph bbox in the 30 viewBox: x 5.7…24.3, y 7.1…22.91.
        // Fit the full 30×30 viewBox into the frame (uniform scale).
        let scale = min(canvas.width, canvas.height) / 30.0
        let xInset = (canvas.width - 30 * scale) / 2
        let yInset = (canvas.height - 30 * scale) / 2
        func p(_ point: (CGFloat, CGFloat)) -> CGPoint {
            CGPoint(x: canvas.minX + point.0 * scale + xInset, y: canvas.minY + point.1 * scale + yInset)
        }
        var path = Path()
        for polygon in Self.polygons {
            guard let first = polygon.first else { continue }
            path.move(to: p(first))
            for point in polygon.dropFirst() {
                path.addLine(to: p(point))
            }
            path.closeSubpath()
        }
        return path
    }
}
