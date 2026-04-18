import SwiftUI

@Observable
final class NotchCoordinator {
    enum Status {
        case closed
        case popping
        case opened
    }

    var status: Status = .closed
    var selectedTab: Tab = .media

    let window: NotchWindow
    private var hostingController: NSHostingController<NotchView>?

    private(set) var notchSize: NSSize
    private(set) var screenFrame: NSRect
    private let hitboxPadding: CGFloat = 10
    private let openedWidth: CGFloat = 500
    private let openedHeight: CGFloat = 260

    let mediaService: MediaService
    let calendarService: CalendarService
    let claudeCodeService: ClaudeCodeService
    let launcherService: LauncherService
    let appSettings: AppSettings

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
        case .popping: NSSize(width: max(notchSize.width + 20, CGFloat(appSettings.enabledTabs.count) * 56 + 20), height: notchSize.height + 52)
        case .opened: NSSize(width: openedWidth, height: openedHeight)
        }
    }

    private var hitboxRect: NSRect {
        deviceNotchRect.insetBy(dx: -hitboxPadding, dy: -hitboxPadding)
    }

    init(
        mediaService: MediaService,
        calendarService: CalendarService,
        claudeCodeService: ClaudeCodeService,
        launcherService: LauncherService,
        appSettings: AppSettings
    ) {
        self.mediaService = mediaService
        self.calendarService = calendarService
        self.claudeCodeService = claudeCodeService
        self.launcherService = launcherService
        self.appSettings = appSettings

        let screen = NSScreen.main!
        self.screenFrame = screen.frame
        self.notchSize = screen.hasNotch
            ? (screen.notchSize ?? NSSize(width: 200, height: 32))
            : NSSize(width: 200, height: 32)

        self.window = NotchWindow(rect: screen.frame)

        let wrapper = NotchView(
            coordinator: self,
            enabledTabs: appSettings.enabledTabs,
            mediaService: mediaService,
            calendarService: calendarService,
            claudeService: claudeCodeService
        )
        let hosting = NSHostingController(rootView: wrapper)
        hosting.view.frame = screen.frame
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        self.hostingController = hosting

        window.contentView = hosting.view
        window.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        setupEventMonitoring()
        setupDefocusHandling()
    }

    func notchPop() {
        guard status == .closed else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        withAnimation(.interactiveSpring(duration: 0.314)) {
            status = .popping
        }
    }

    func notchOpen(tab: Tab? = nil) {
        if let tab { selectedTab = tab }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .default)
        withAnimation(.interactiveSpring(duration: 0.314)) {
            status = .opened
        }
    }

    func notchClose() {
        withAnimation(.spring(duration: 0.236)) {
            status = .closed
        }
    }

    @objc private func screenParametersChanged() {
        let screen = NSScreen.main!
        screenFrame = screen.frame
        notchSize = screen.hasNotch
            ? (screen.notchSize ?? NSSize(width: 200, height: 32))
            : NSSize(width: 200, height: 32)
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
            if isInHitbox { notchPop() }
        case .popping, .opened:
            let contentRect = NSRect(
                x: screenFrame.midX - contentSize.width / 2,
                y: screenFrame.maxY - contentSize.height,
                width: contentSize.width,
                height: contentSize.height
            )
            if !NSMouseInRect(location, contentRect.insetBy(dx: -20, dy: -20), false) {
                notchClose()
            }
        }
    }

    private func handleMouseDown() {
        let location = NSEvent.mouseLocation
        if status == .closed && NSMouseInRect(location, hitboxRect, false) {
            notchPop()
        }
    }

    private func setupDefocusHandling() {
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return }
            guard self.status != .closed else { return }
            let location = event.locationInWindow
            let screenPoint = NSEvent.mouseLocation
            let contentRect = NSRect(
                x: self.screenFrame.midX - self.contentSize.width / 2,
                y: self.screenFrame.maxY - self.contentSize.height,
                width: self.contentSize.width,
                height: self.contentSize.height
            )
            if !NSMouseInRect(screenPoint, contentRect.insetBy(dx: -10, dy: -10), false) {
                self.notchClose()
            }
        }
    }
}
