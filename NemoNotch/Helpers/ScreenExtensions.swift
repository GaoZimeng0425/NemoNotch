import AppKit

extension NSScreen {
    static var screenWithMouse: NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
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

    var notchFrame: NSRect {
        let size = notchSize
        guard size.width > 0 else { return .zero }
        return .init(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
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
