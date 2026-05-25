import AppKit
@testable import NemoNotch
import Testing

@Suite("NSScreen positioning helpers")
struct ScreenExtensionsTests {
    @Test("screen(containing:) returns nil for unreachable point")
    @MainActor
    func unreachablePoint() {
        let far = CGPoint(x: -100_000, y: -100_000)
        #expect(NSScreen.screen(containing: far) == nil)
    }

    @Test("screen(containing:) finds a screen for a point inside main's frame")
    @MainActor
    func insideMain() {
        guard let main = NSScreen.main else {
            // Headless CI — skip rather than fail.
            return
        }
        let inside = CGPoint(
            x: main.frame.midX,
            y: main.frame.midY
        )
        #expect(NSScreen.screen(containing: inside) != nil)
    }

    @Test("screenWithMouse resolves on a system with displays")
    @MainActor
    func mouseScreenResolves() {
        guard !NSScreen.screens.isEmpty else { return }
        #expect(NSScreen.screenWithMouse != nil)
    }
}
