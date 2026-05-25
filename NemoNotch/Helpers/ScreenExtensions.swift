import AppKit

extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }

    /// Returns the screen whose frame contains the given point (in global
    /// AppKit coordinates), or nil if no screen does. Mirrors `screenWithMouse`
    /// but accepts an explicit point — use this for click/touch events whose
    /// location is already known.
    static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    var hasNotch: Bool {
        safeAreaInsets.top > 0
            && (auxiliaryTopLeftArea?.width ?? 0) > 0
            && (auxiliaryTopRightArea?.width ?? 0) > 0
    }

    var notchSize: NSSize {
        guard hasNotch else { return .zero }
        let notchHeight = safeAreaInsets.top
        let notchWidth = frame.width
            - (auxiliaryTopLeftArea?.width ?? 0)
            - (auxiliaryTopRightArea?.width ?? 0)
        return .init(width: notchWidth, height: notchHeight)
    }

    var displayID: UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screenNumber = deviceDescription[key] as? NSNumber else { return 0 }
        return screenNumber.uint32Value
    }

    var isBuiltInDisplay: Bool {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let id = deviceDescription[key],
              let screenID = (id as? NSNumber)?.uint32Value,
              CGDisplayIsBuiltin(screenID) == 1
        else { return false }
        return true
    }
}
