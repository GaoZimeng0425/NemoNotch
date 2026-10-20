import SwiftUI

/// opencode's brand mark, redrawn as a tintable vector (source: opencode.ai
/// favicon, viewBox 512). It's a hollow rectangular "portal" frame with a
/// filled lower-inner block. Mirrors `ClaudeCrabIcon`'s `size`/`color` API so
/// it drops into the same badge / source-icon slots. Drawn as shapes, not a
/// `Canvas`: a Canvas in the edge bar's first ring, above the working ring's
/// arc NSView, came out with its bottom cut off (see `EdgeBarCrab`).
struct OpencodeLogoIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = .white) {
        self.size = size
        self.color = color
    }

    var body: some View {
        ZStack {
            OpencodeLogoShape(part: .frame).fill(color, style: FillStyle(eoFill: true))
            // Inner block — echo the logo's two-tone via reduced opacity.
            OpencodeLogoShape(part: .block).fill(color.opacity(0.5))
        }
        .frame(width: size, height: size)
    }
}

/// The two parts of opencode's mark, in the 512 viewBox.
struct OpencodeLogoShape: Shape {
    enum Part {
        /// Outer rect minus the inner hole (fill even-odd).
        case frame
        case block
    }

    let part: Part

    func path(in canvas: CGRect) -> Path {
        // Logo content bbox in the 512 viewBox: x 128…384 (w256),
        // y 96…416 (h320). Fit by height, centered horizontally.
        let scale = canvas.height / 320.0
        let xInset = (canvas.width - 256 * scale) / 2
        func rect(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGRect {
            CGRect(
                x: canvas.minX + (x1 - 128) * scale + xInset,
                y: canvas.minY + (y1 - 96) * scale,
                width: (x2 - x1) * scale,
                height: (y2 - y1) * scale
            )
        }
        var path = Path()
        switch part {
        case .frame:
            path.addRect(rect(128, 96, 384, 416))
            path.addRect(rect(192, 160, 320, 352))
        case .block:
            path.addRect(rect(192, 224, 320, 352))
        }
        return path
    }
}
