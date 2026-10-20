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

    /// Every screen resolves to ITSELF at its centre and at its inclusive
    /// (left and top) edges. `screenWithMouse` is this with the live cursor;
    /// asserting on the live cursor itself made the test depend on where the
    /// user's mouse happened to be during the run.
    @Test("screen(containing:) resolves each screen to itself")
    @MainActor
    func eachScreenResolvesToItself() {
        for screen in NSScreen.screens {
            let f = screen.frame
            for point in [CGPoint(x: f.midX, y: f.midY), CGPoint(x: f.minX, y: f.midY), CGPoint(x: f.midX, y: f.maxY)] {
                #expect(NSScreen.screen(containing: point)?.displayID == screen.displayID, "\(point) on \(f)")
            }
        }
    }
}
