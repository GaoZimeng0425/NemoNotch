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
    /// The screen currently driving expansion. Only this screen's window
    /// reflects the opened state; others remain collapsed but stay visible
    /// to display badges. `nil` outside of an open session.
    private(set) var activeScreen: NSScreen?
    private var isContextMenuVisible = false
    private var contextMenuDelegate: ContextMenuDelegate?
    var autoSelectTab: (() -> Tab?)?
    var appSettings: AppSettings?

    /// Unified across all screens — derived once from the built-in display's
    /// physical notch, or a default fallback for headless / external-only setups.
    private(set) var notchSize: NSSize

    /// Per-screen window infrastructure, keyed by CGDirectDisplayID.
    private var slots: [UInt32: NotchWindowSlot] = [:]
    private let contentBuilder: (NotchCoordinator, NSScreen) -> AnyView

    private var previousApp: NSRunningApplication?
    private static let ourBundleIdentifier = Bundle.main.bundleIdentifier
    private static let windowWidth: CGFloat = 800
    private static let windowHeight: CGFloat = 340

    // MARK: - Geometry

    func deviceNotchRect(for screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.midX - notchSize.width / 2,
            y: screen.frame.maxY - notchSize.height,
            width: notchSize.width,
            height: notchSize.height
        )
    }

    func hitboxRect(for screen: NSScreen) -> NSRect {
        deviceNotchRect(for: screen).insetBy(dx: -NotchConstants.hitboxPadding, dy: -NotchConstants.hitboxPadding)
    }

    var openedWidth: CGFloat {
        selectedTab == .overview ? NotchConstants.overviewOpenedWidth : NotchConstants.openedWidth
    }

    var contentSize: NSSize {
        switch status {
        case .closed: notchSize
        case .opened: NSSize(width: openedWidth, height: NotchConstants.openedHeight)
        }
    }

    private func contentRect(for screen: NSScreen, hitInset: CGFloat) -> NSRect {
        let rect = NSRect(
            x: screen.frame.midX - contentSize.width / 2,
            y: screen.frame.maxY - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
        return rect.insetBy(dx: -hitInset, dy: -hitInset)
    }

    // MARK: - Init

    init(content: @escaping (NotchCoordinator, NSScreen) -> AnyView) {
        self.contentBuilder = content
        self.notchSize = Self.resolveUnifiedNotchSize()

        rebuildSlots()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        setupEventMonitoring()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Use the built-in display's physical notch when available, otherwise
    /// fall back to defaults — guarantees a sensible unified size on Macs
    /// without a notch (Mac mini, Mac Pro, clamshell).
    private static func resolveUnifiedNotchSize() -> NSSize {
        if let builtin = NSScreen.screens.first(where: { $0.isBuiltInDisplay && $0.hasNotch }) {
            return builtin.notchSize
        }
        return NSSize(width: NotchConstants.defaultNotchWidth, height: NotchConstants.defaultNotchHeight)
    }

    // MARK: - Slot Management

    private func rebuildSlots() {
        let currentIDs = Set(NSScreen.screens.map(\.displayID))

        // Remove slots for screens that disappeared.
        for (id, slot) in slots where !currentIDs.contains(id) {
            slot.close()
            slots.removeValue(forKey: id)
        }

        // Add or update slots for current screens.
        for screen in NSScreen.screens {
            let id = screen.displayID
            if let existing = slots[id] {
                existing.updateFrame(for: screen)
            } else {
                slots[id] = makeSlot(for: screen)
            }
        }
    }

    private func makeSlot(for screen: NSScreen) -> NotchWindowSlot {
        let wf = Self.windowFrame(for: screen)
        let window = NotchWindow(rect: wf)
        let passThrough = PassThroughView(frame: NSRect(x: 0, y: 0, width: wf.width, height: wf.height))
        passThrough.wantsLayer = true
        passThrough.layer?.backgroundColor = .clear

        let hosting = NSHostingController(rootView: contentBuilder(self, screen))
        let sf = screen.frame
        hosting.view.frame = NSRect(
            x: sf.minX - wf.minX,
            y: sf.minY - wf.minY,
            width: sf.width,
            height: sf.height
        )
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear

        passThrough.addSubview(hosting.view)
        window.contentView = passThrough
        window.orderFrontRegardless()

        return NotchWindowSlot(displayID: screen.displayID, window: window, passThrough: passThrough, hostingController: hosting)
    }

    private static func windowFrame(for screen: NSScreen) -> NSRect {
        let sf = screen.frame
        return NSRect(
            x: sf.midX - windowWidth / 2,
            y: sf.maxY - windowHeight,
            width: windowWidth,
            height: windowHeight
        )
    }

    // MARK: - Open / Close

    /// True if `screen` is the one currently driving expansion. NotchView
    /// uses this to render either the opened or collapsed state per window.
    func isActiveScreen(_ screen: NSScreen) -> Bool {
        activeScreen?.displayID == screen.displayID
    }

    func notchOpen(tab: Tab? = nil, on screen: NSScreen? = nil) {
        guard status == .closed else { return }
        let target = screen ?? NSScreen.screenWithMouse ?? NSScreen.main ?? NSScreen.screens.first
        guard let target, let slot = slots[target.displayID] else { return }

        captureFrontmostApp()
        if let tab {
            selectedTab = tab
        } else if let auto = autoSelectTab?() {
            selectedTab = auto
        }
        activeScreen = target
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        withAnimation(.interactiveSpring(duration: NotchConstants.openSpringDuration)) {
            status = .opened
        }
        slot.passThrough.isBlocking = true
        slot.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func notchClose() {
        let openedScreen = activeScreen
        withAnimation(.spring(duration: NotchConstants.closeSpringDuration)) {
            status = .closed
        }
        if let openedScreen, let slot = slots[openedScreen.displayID] {
            slot.passThrough.isBlocking = false
            if slot.window.isKeyWindow { slot.window.resignKey() }
        }
        activeScreen = nil
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
        notchSize = Self.resolveUnifiedNotchSize()
        rebuildSlots()
        // If the active screen disappeared mid-session, gracefully collapse.
        if let active = activeScreen, slots[active.displayID] == nil {
            activeScreen = nil
            status = .closed
        }
    }

    // MARK: - Event Routing

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

    /// Locate the screen currently under the given mouse point. Used to
    /// scope event handling to the correct slot.
    private func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func handleMouseMove(_ location: NSPoint) {
        guard !isContextMenuVisible else { return }

        switch status {
        case .closed:
            guard let screen = screen(at: location) else { return }
            if NSMouseInRect(location, hitboxRect(for: screen), false) {
                notchOpen(on: screen)
            }
        case .opened:
            guard let active = activeScreen else { return }
            let contentHit = contentRect(for: active, hitInset: NotchConstants.closeHitboxInset)
            if !NSMouseInRect(location, contentHit, false) {
                notchClose()
            }
        }
    }

    private func handleMouseDown() {
        guard !isContextMenuVisible else { return }
        let location = NSEvent.mouseLocation

        if status == .closed {
            guard let screen = screen(at: location) else { return }
            if NSMouseInRect(location, hitboxRect(for: screen), false) {
                notchOpen(on: screen)
            }
            return
        }

        if status == .opened, let active = activeScreen {
            let contentHit = contentRect(for: active, hitInset: NotchConstants.clickHitboxInset)
            if !NSMouseInRect(location, contentHit, false) {
                notchClose()
            }
        }
    }

    private func handleRightMouseDown(_ point: NSPoint) {
        let isInNotch: Bool
        switch status {
        case .closed:
            guard let screen = screen(at: point) else { return }
            isInNotch = NSMouseInRect(point, hitboxRect(for: screen), false)
        case .opened:
            guard let active = activeScreen else { return }
            let contentHit = contentRect(for: active, hitInset: NotchConstants.clickHitboxInset)
            isInNotch = NSMouseInRect(point, contentHit, false)
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

// MARK: - NotchWindowSlot

/// Owns the per-screen NSPanel infrastructure. The coordinator holds one of
/// these per connected screen.
@MainActor
final class NotchWindowSlot {
    let displayID: UInt32
    let window: NotchWindow
    let passThrough: PassThroughView
    let hostingController: NSHostingController<AnyView>

    init(displayID: UInt32, window: NotchWindow, passThrough: PassThroughView, hostingController: NSHostingController<AnyView>) {
        self.displayID = displayID
        self.window = window
        self.passThrough = passThrough
        self.hostingController = hostingController
    }

    func updateFrame(for screen: NSScreen) {
        let sf = screen.frame
        let wf = NSRect(
            x: sf.midX - window.frame.width / 2,
            y: sf.maxY - window.frame.height,
            width: window.frame.width,
            height: window.frame.height
        )
        window.setFrame(wf, display: true)
        hostingController.view.frame = NSRect(
            x: sf.minX - wf.minX,
            y: sf.minY - wf.minY,
            width: sf.width,
            height: sf.height
        )
    }

    func close() {
        window.orderOut(nil)
        window.close()
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
