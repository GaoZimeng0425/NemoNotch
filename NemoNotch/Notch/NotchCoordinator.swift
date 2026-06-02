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
    private var dismissState = HotkeyDismissState()
    private var hotkeyAutoCloseTimer: Timer?
    private var escMonitor: Any?
    var autoSelectTab: (() -> Tab?)?
    var appSettings: AppSettings?
    var restoreSuppressionCheck: (() -> Bool)?
    /// Fired every time the notch transitions from closed to opened, before the
    /// expand animation. Used to refresh per-session UI state (e.g. snap the
    /// calendar back to today).
    var onOpen: (() -> Void)?

    /// Unified across all screens — derived once from the built-in display's
    /// physical notch, or a default fallback for headless / external-only setups.
    private(set) var notchSize: NSSize

    /// Per-screen window infrastructure, keyed by CGDirectDisplayID.
    private var slots: [UInt32: NotchWindowSlot] = [:]
    private let contentBuilder: (NotchCoordinator, NSScreen) -> AnyView

    private var previousApp: NSRunningApplication?
    private static let ourBundleIdentifier = Bundle.main.bundleIdentifier
    private static let windowWidth: CGFloat = 800
    private static let windowHeight: CGFloat = 430

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
        contentBuilder = content
        notchSize = Self.resolveUnifiedNotchSize()

        rebuildSlots()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // uitest 下不装鼠标事件监听:程序化 notchOpen 后面板需常驻供截图,
        // 否则鼠标在内容区外会触发 HotkeyDismissState.shouldClose 立刻收起。
        if !UITestMode.isActive {
            setupEventMonitoring()
        }
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

        return NotchWindowSlot(
            displayID: screen.displayID,
            window: window,
            passThrough: passThrough,
            hostingController: hosting
        )
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

    func notchOpen(tab: Tab? = nil, on screen: NSScreen? = nil, viaHotkey: Bool = false) {
        guard status == .closed else { return }
        let target = screen ?? NSScreen.screenWithMouse ?? NSScreen.main ?? NSScreen.screens.first
        guard let target, let slot = slots[target.displayID] else { return }

        captureFrontmostApp()
        onOpen?()
        if let tab {
            selectedTab = tab
        } else if let auto = autoSelectTab?() {
            selectedTab = auto
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        withAnimation(.interactiveSpring(duration: NotchConstants.openSpringDuration)) {
            activeScreen = target
            status = .opened
        }
        dismissState.didOpen(viaHotkey: viaHotkey)
        if viaHotkey {
            startHotkeyAutoCloseTimer()
        }
        slot.passThrough.isBlocking = true
        slot.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installEscMonitor()
    }

    func notchClose() {
        dismissState.reset()
        cancelHotkeyAutoCloseTimer()
        uninstallEscMonitor()
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

    private func captureFrontmostApp() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Self.ourBundleIdentifier {
            previousApp = frontmost
        }
    }

    private func restorePreviousApp() {
        if restoreSuppressionCheck?() == true {
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
    }

    /// Locate the screen currently under the given mouse point. Used to
    /// scope event handling to the correct slot.
    private func screen(at point: NSPoint) -> NSScreen? {
        NSScreen.screen(containing: point)
    }

    private func handleMouseMove(_ location: NSPoint) {
        switch status {
        case .closed:
            guard let screen = screen(at: location) else { return }
            if NSMouseInRect(location, hitboxRect(for: screen), false) {
                notchOpen(on: screen)
            }
        case .opened:
            guard let active = activeScreen else { return }
            let contentHit = contentRect(for: active, hitInset: NotchConstants.closeHitboxInset)
            let mouseInside = NSMouseInRect(location, contentHit, false)
            switch dismissState.observe(mouseInside: mouseInside) {
            case .ignore: break
            case .markedEntered: cancelHotkeyAutoCloseTimer()
            case .shouldClose: notchClose()
            }
        }
    }

    private func handleMouseDown() {
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

    // MARK: - Hotkey auto-close timer

    private func startHotkeyAutoCloseTimer() {
        cancelHotkeyAutoCloseTimer()
        hotkeyAutoCloseTimer = Timer.scheduledTimer(
            withTimeInterval: NotchConstants.hotkeyAutoCloseDelay,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.notchClose()
            }
        }
        LogService.debug(
            "NotchCoordinator: hotkey auto-close armed (\(NotchConstants.hotkeyAutoCloseDelay)s)",
            category: "NotchCoordinator"
        )
    }

    private func cancelHotkeyAutoCloseTimer() {
        guard hotkeyAutoCloseTimer != nil else { return }
        hotkeyAutoCloseTimer?.invalidate()
        hotkeyAutoCloseTimer = nil
        LogService.debug(
            "NotchCoordinator: hotkey auto-close cancelled",
            category: "NotchCoordinator"
        )
    }

    // MARK: - ESC monitor

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // kVK_Escape = 53
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in
                    guard let self, status == .opened else { return }
                    notchClose()
                }
                return nil // swallow event
            }
            return event
        }
    }

    private func uninstallEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    /// Restart the 3-second grace period. Called when the user uses the
    /// keyboard to switch tabs while the notch is still in its "no-mouse-yet"
    /// phase — treated as continued keyboard engagement.
    func bumpHotkeyAutoCloseTimerIfActive() {
        guard dismissState.openedViaHotkey, !dismissState.mouseHasEnteredContent else { return }
        startHotkeyAutoCloseTimer()
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

    init(
        displayID: UInt32,
        window: NotchWindow,
        passThrough: PassThroughView,
        hostingController: NSHostingController<AnyView>
    ) {
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
