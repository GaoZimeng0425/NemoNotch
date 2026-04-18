import SwiftUI

@Observable
final class NotchCoordinator {
    enum Status {
        case closed
        case opened
    }

    var status: Status = .closed
    var selectedTab: Tab = .media
    var autoSelectTab: (() -> Tab?)?

    let window: NotchWindow
    private var hostingController: NSHostingController<AnyView>?

    private(set) var notchSize: NSSize
    private(set) var screenFrame: NSRect

    private var previousApp: NSRunningApplication?
    private static let ourBundleIdentifier = Bundle.main.bundleIdentifier

    private var deviceNotchRect: NSRect {
        let screen = NSScreen.main!
        return NSRect(
            x: screen.frame.midX - notchSize.width / 2,
            y: screen.frame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }

    var contentSize: NSSize {
        switch status {
        case .closed: notchSize
        case .opened: NSSize(width: NotchConstants.openedWidth, height: NotchConstants.openedHeight)
        }
    }

    private var hitboxRect: NSRect {
        deviceNotchRect.insetBy(dx: -NotchConstants.hitboxPadding, dy: -NotchConstants.hitboxPadding)
    }

    init(content: (NotchCoordinator) -> AnyView) {
        let screen = NSScreen.main!
        self.screenFrame = screen.frame
        self.notchSize = screen.hasNotch
            ? (screen.notchSize ?? NSSize(width: NotchConstants.defaultNotchWidth, height: NotchConstants.defaultNotchHeight))
            : NSSize(width: NotchConstants.defaultNotchWidth, height: NotchConstants.defaultNotchHeight)

        self.window = NotchWindow(rect: screen.frame)

        let hosting = NSHostingController(rootView: content(self))
        hosting.view.frame = screen.frame
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        self.hostingController = hosting

        let passThrough = PassThroughView(frame: screen.frame)
        passThrough.wantsLayer = true
        passThrough.layer?.backgroundColor = .clear
        passThrough.addSubview(hosting.view)
        window.contentView = passThrough
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        setupEventMonitoring()
    }

    func notchOpen(tab: Tab? = nil) {
        guard status == .closed else { return }
        captureFrontmostApp()
        if let tab {
            selectedTab = tab
        } else if let auto = autoSelectTab?() {
            selectedTab = auto
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        withAnimation(.interactiveSpring(duration: NotchConstants.openSpringDuration)) {
            status = .opened
        }
    }

    func notchClose() {
        withAnimation(.spring(duration: NotchConstants.closeSpringDuration)) {
            status = .closed
        }
        if window.isKeyWindow {
            window.resignKey()
        }
        restorePreviousApp()
    }

    private func captureFrontmostApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Self.ourBundleIdentifier {
            previousApp = frontmost
        }
    }

    private func restorePreviousApp() {
        guard let app = previousApp else { return }
        previousApp = nil
        let currentFront = NSWorkspace.shared.frontmostApplication
        let currentID = currentFront?.bundleIdentifier
        if currentFront == nil || currentID == Self.ourBundleIdentifier {
            app.activate()
        }
    }

    @objc private func screenParametersChanged() {
        let screen = NSScreen.main!
        screenFrame = screen.frame
        notchSize = screen.hasNotch
            ? (screen.notchSize ?? NSSize(width: NotchConstants.defaultNotchWidth, height: NotchConstants.defaultNotchHeight))
            : NSSize(width: NotchConstants.defaultNotchWidth, height: NotchConstants.defaultNotchHeight)
        window.setFrame(screen.frame, display: true)
        hostingController?.view.frame = screen.frame
    }

    private func setupEventMonitoring() {
        let monitor = EventMonitor.shared
        monitor.onMouseMove = { [weak self] location in
            self?.handleMouseMove(location)
        }
        monitor.onMouseDown = { [weak self] in
            self?.handleMouseDown()
        }
    }

    private func handleMouseMove(_ location: NSPoint) {
        let hitbox = hitboxRect
        let isInHitbox = NSMouseInRect(location, hitbox, false)

        switch status {
        case .closed:
            if isInHitbox { notchOpen() }
        case .opened:
            let contentRect = NSRect(
                x: screenFrame.midX - contentSize.width / 2,
                y: screenFrame.maxY - contentSize.height,
                width: contentSize.width,
                height: contentSize.height
            )
            if !NSMouseInRect(location, contentRect.insetBy(dx: -NotchConstants.closeHitboxInset, dy: -NotchConstants.closeHitboxInset), false) {
                notchClose()
            }
        }
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation
        if status == .closed && NSMouseInRect(location, hitboxRect, false) {
            notchOpen()
        }
        if status == .opened {
            let contentRect = NSRect(
                x: screenFrame.midX - contentSize.width / 2,
                y: screenFrame.maxY - contentSize.height,
                width: contentSize.width,
                height: contentSize.height
            )
            if !NSMouseInRect(location, contentRect.insetBy(dx: -NotchConstants.clickHitboxInset, dy: -NotchConstants.clickHitboxInset), false) {
                notchClose()
            }
        }
    }
}
