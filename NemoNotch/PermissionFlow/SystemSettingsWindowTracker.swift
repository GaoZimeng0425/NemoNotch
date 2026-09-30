import AppKit
import CoreGraphics
import Foundation

/// Locates the frontmost System Settings window without needing Accessibility
/// permission.
///
/// This is the bootstrap that makes the whole drag-to-authorize flow possible:
/// reading another app's window frame *through the Accessibility API* would
/// itself require Accessibility trust — the exact permission we are trying to
/// obtain. `CGWindowListCopyWindowInfo` is a Window Server query and needs no
/// TCC grant at all (verified on macOS 26 Tahoe: owner PID, window layer and
/// bounds are all returned for other processes with no prompt).
enum SystemSettingsWindowTracker {
    static let bundleIdentifier = "com.apple.systempreferences"

    /// PIDs of every running System Settings instance, or an empty set.
    private static var settingsPIDs: Set<Int32> {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleIdentifier }
        return Set(apps.map { $0.processIdentifier })
    }

    /// Frame of the frontmost on-screen System Settings window, in AppKit
    /// coordinates (bottom-left origin). `nil` when System Settings has no
    /// visible window.
    static func frontmostWindowFrame() -> CGRect? {
        let pids = settingsPIDs
        guard !pids.isEmpty else { return nil }

        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
            as? [[String: Any]]
        else { return nil }

        // The window list is ordered front-to-back, so the first match is the
        // window the user is actually looking at.
        for entry in windows {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int32,
                  pids.contains(ownerPID)
            else { continue }
            // Layer 0 is the normal window band — filters out the app's
            // tooltips, sheets-in-waiting and offscreen scratch windows.
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = cgRect(from: bounds)
            else { continue }
            // Guard against degenerate 1pt helper windows reported on some
            // macOS versions.
            guard cgRect.width >= 200, cgRect.height >= 150 else { continue }
            return toAppKit(cgRect)
        }
        return nil
    }

    // MARK: - Coordinate conversion

    /// Window Server reports bounds in a top-left-origin space anchored to the
    /// primary display; AppKit wants bottom-left origin. Verified empirically:
    /// `appKitY = primaryScreenHeight - cgY - cgHeight`, `x` unchanged.
    private static func toAppKit(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
        else { return rect }
        return CGRect(
            x: rect.origin.x,
            y: primary.frame.height - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func cgRect(from bounds: [String: Any]) -> CGRect? {
        guard let x = number(bounds["X"]),
              let y = number(bounds["Y"]),
              let width = number(bounds["Width"]),
              let height = number(bounds["Height"])
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// `kCGWindowBounds` values arrive as CFNumber and may bridge to either
    /// Int or Double depending on the value; normalize through NSNumber.
    private static func number(_ value: Any?) -> CGFloat? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return CGFloat(number.doubleValue) }
        return nil
    }
}
