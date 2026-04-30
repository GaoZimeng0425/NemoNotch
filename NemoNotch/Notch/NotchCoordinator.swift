import SwiftUI

@MainActor
@Observable
final class NotchCoordinator {
    enum Status {
        case closed
        case opened
    }

    var status: Status = .closed
    var selectedTab: Tab = .overview
    private var isContextMenuVisible = false
    private var contextMenuDelegate: ContextMenuDelegate?
    var autoSelectTab: (() -> Tab?)?
    var appSettings: AppSettings?

    let window: NotchWindow
    private let passThrough: PassThroughView
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

    private static let windowWidth: CGFloat = 700
    private static let windowHeight: CGFloat = 340

    init(content: (NotchCoordinator) -> AnyView) {
        let screen = NSScreen.main!
        self.screenFrame = screen.frame
        self.notchSize = screen.hasNotch
            ? screen.notchSize
            : NSSize(width: NotchConstants.defaultNotchWidth, height: NotchConstants.defaultNotchHeight)

        let sf = screen.frame
        let wf = NSRect(
            x: sf.midX - Self.windowWidth / 2,
            y: sf.maxY - Self.windowHeight,
            width: Self.windowWidth,
            height: Self.windowHeight
        )
        self.window = NotchWindow(rect: wf)

        let passThrough = PassThroughView(frame: NSRect(x: 0, y: 0, width: wf.width, height: wf.height))
        passThrough.wantsLayer = true
        passThrough.layer?.backgroundColor = .clear
        self.passThrough = passThrough

        let hosting = NSHostingController(rootView: content(self))
        hosting.view.frame = NSRect(
            x: sf.minX - wf.minX,
            y: sf.minY - wf.minY,
            width: sf.width,
            height: sf.height
        )
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        self.hostingController = hosting

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
        passThrough.isBlocking = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func notchClose() {
        withAnimation(.spring(duration: NotchConstants.closeSpringDuration)) {
            status = .closed
        }
        passThrough.isBlocking = false
        if window.isKeyWindow {
            window.resignKey()
        }
        restorePreviousApp()
    }

    func selectNextTab() {
        guard let settings = appSettings else { return }
        let tabs = Tab.sorted(settings.enabledTabs)
        guard let index = tabs.firstIndex(of: selectedTab), index + 1 < tabs.count else { return }
        selectedTab = tabs[index + 1]
    }

    func selectPreviousTab() {
        guard let settings = appSettings else { return }
        let tabs = Tab.sorted(settings.enabledTabs)
        guard let index = tabs.firstIndex(of: selectedTab), index > 0 else { return }
        selectedTab = tabs[index - 1]
    }

    private func captureFrontmostApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Self.ourBundleIdentifier {
            previousApp = frontmost
        }
    }

    private func restorePreviousApp() {
        if AppDelegate.shared.shouldSuppressPreviousAppRestore {
            previousApp = nil
            return
        }
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
            ? screen.notchSize
            : NSSize(width: NotchConstants.defaultNotchWidth, height: NotchConstants.defaultNotchHeight)
        let sf = screenFrame
        let wf = NSRect(
            x: sf.midX - Self.windowWidth / 2,
            y: sf.maxY - Self.windowHeight,
            width: Self.windowWidth,
            height: Self.windowHeight
        )
        window.setFrame(wf, display: true)
        hostingController?.view.frame = NSRect(
            x: sf.minX - wf.minX,
            y: sf.minY - wf.minY,
            width: sf.width,
            height: sf.height
        )
    }

    private func setupEventMonitoring() {
        let monitor = EventMonitor.shared
        monitor.onMouseMove = { [weak self] location in
            self?.handleMouseMove(location)
        }
        monitor.onMouseDown = { [weak self] in
            self?.handleMouseDown()
        }
        monitor.onRightMouseDown = { [weak self] point in
            self?.handleRightMouseDown(point)
        }
    }

    private func handleMouseMove(_ location: NSPoint) {
        guard !isContextMenuVisible else { return }
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
            let isInContent = NSMouseInRect(location, contentRect.insetBy(dx: -NotchConstants.closeHitboxInset, dy: -NotchConstants.closeHitboxInset), false)
            if !isInContent {
                notchClose()
            }
        }
    }

    private func handleMouseDown() {
        guard !isContextMenuVisible else { return }
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
            let isInContent = NSMouseInRect(location, contentRect.insetBy(dx: -NotchConstants.clickHitboxInset, dy: -NotchConstants.clickHitboxInset), false)
            if !isInContent {
                notchClose()
            }
        }
    }

    private func handleRightMouseDown(_ point: NSPoint) {
        let isInNotch: Bool
        switch status {
        case .closed:
            isInNotch = NSMouseInRect(point, hitboxRect, false)
        case .opened:
            let contentRect = NSRect(
                x: screenFrame.midX - contentSize.width / 2,
                y: screenFrame.maxY - contentSize.height,
                width: contentSize.width,
                height: contentSize.height
            )
            isInNotch = NSMouseInRect(point, contentRect.insetBy(dx: -NotchConstants.clickHitboxInset, dy: -NotchConstants.clickHitboxInset), false)
        }
        guard isInNotch else { return }

        isContextMenuVisible = true
        let menu = NSMenu()
        let delegate = ContextMenuDelegate(
            onClose: { [weak self] in self?.isContextMenuVisible = false },
            onSettings: { @MainActor in AppDelegate.shared.showSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        contextMenuDelegate = delegate
        menu.delegate = delegate
        let settingsItem = NSMenuItem(title: String(localized: "notch.context.settings"), action: #selector(ContextMenuDelegate.openSettings), keyEquivalent: ",")
        settingsItem.target = delegate
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: String(localized: "notch.context.quit"), action: #selector(ContextMenuDelegate.quitApp), keyEquivalent: "q")
        quitItem.target = delegate
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: point, in: nil)
    }
}

private final class ContextMenuDelegate: NSObject, NSMenuDelegate {
    let onClose: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void
    init(onClose: @escaping () -> Void, onSettings: @escaping () -> Void, onQuit: @escaping () -> Void) {
        self.onClose = onClose
        self.onSettings = onSettings
        self.onQuit = onQuit
    }
    func menuDidClose(_ menu: NSMenu) { onClose() }
    @objc func openSettings() { onSettings() }
    @objc func quitApp() { onQuit() }
}
