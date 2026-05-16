import AppKit
import SwiftUI

/// Fixed pixel-art notch shape rendered as an explicit template NSImage.
/// Geometry mirrors scripts/generate-app-icon.swift — same 12 × 12 grid,
/// three horizontal bars. MenuBarExtra requires a template image to render
/// correctly in the menubar (SwiftUI Shape views are not part of the
/// supported MenuBarExtra label contract on macOS 14+).
struct MenuBarLabel: View {
    var body: some View {
        Image(nsImage: Self.iconImage)
    }

    private static let iconImage: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let cell = rect.width / 12
            NSColor.black.setFill()
            NSRect(x: 0, y: 4 * cell, width: 12 * cell, height: cell).fill()
            NSRect(x: 2 * cell, y: 5 * cell, width: 8 * cell, height: cell).fill()
            NSRect(x: 3 * cell, y: 6 * cell, width: 6 * cell, height: cell).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
