import SwiftUI

/// Fixed pixel-art notch shape rendered live for the menubar. Geometry mirrors
/// scripts/generate-app-icon.swift — same 12 × 12 grid, three horizontal bars.
/// State information lives on the notch panel above the menubar, not here.
struct MenuBarLabel: View {
    var body: some View {
        NotchPixelShape()
            .fill(.primary)
            .frame(width: 18, height: 18)
    }
}

/// Three horizontal bars on a 12 × 12 grid. Rendered as a Shape (not a
/// Canvas) so the fill style participates in `.foregroundStyle` /
/// `.fill(.primary)` and adapts to the menubar's effective appearance.
private struct NotchPixelShape: Shape {
    func path(in rect: CGRect) -> Path {
        let cell = rect.width / 12
        var path = Path()
        // display top edge (cols 0–11)
        path.addRect(CGRect(x: 0, y: 4 * cell, width: 12 * cell, height: cell))
        // notch body (cols 2–9)
        path.addRect(CGRect(x: 2 * cell, y: 5 * cell, width: 8 * cell, height: cell))
        // chamfer (cols 3–8)
        path.addRect(CGRect(x: 3 * cell, y: 6 * cell, width: 6 * cell, height: cell))
        return path
    }
}
