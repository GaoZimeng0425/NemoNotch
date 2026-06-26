import SwiftUI

/// opencode's brand mark, redrawn as a tintable vector (source: opencode.ai
/// favicon, viewBox 512). It's a hollow rectangular "portal" frame with a
/// filled lower-inner block. Mirrors `ClaudeCrabIcon`'s `size`/`color` API so
/// it drops into the same badge / source-icon slots.
struct OpencodeLogoIcon: View {
    let size: CGFloat
    let color: Color

    init(size: CGFloat = 14, color: Color = .white) {
        self.size = size
        self.color = color
    }

    var body: some View {
        Canvas { ctx, canvas in
            // Logo content bbox in the 512 viewBox: x 128…384 (w256),
            // y 96…416 (h320). Fit by height, centered horizontally.
            let scale = canvas.height / 320.0
            let xInset = (canvas.width - 256 * scale) / 2
            func rect(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> CGRect {
                CGRect(
                    x: (x1 - 128) * scale + xInset,
                    y: (y1 - 96) * scale,
                    width: (x2 - x1) * scale,
                    height: (y2 - y1) * scale
                )
            }

            // Hollow frame: outer rect minus inner hole (even-odd).
            var frame = Path()
            frame.addRect(rect(128, 96, 384, 416))
            frame.addRect(rect(192, 160, 320, 352))
            ctx.fill(frame, with: .color(color), style: FillStyle(eoFill: true))

            // Inner block — echo the logo's two-tone via reduced opacity.
            ctx.fill(Path(rect(192, 224, 320, 352)), with: .color(color.opacity(0.5)))
        }
        .frame(width: size, height: size)
    }
}
