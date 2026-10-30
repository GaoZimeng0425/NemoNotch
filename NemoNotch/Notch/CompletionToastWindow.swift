import AppKit
import SwiftUI

/// The toast row's window: a fixed envelope hanging under the notch, wide
/// enough for `completionToastCapacity` cards. Never resized as cards come and
/// go; areas without a card pass clicks through (`CompletionToastHostingView.hitTest`).
/// Non-activating: clicking a card's close button never takes focus from the
/// front app (the user's terminal).
final class CompletionToastPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    init(frame: NSRect, hosting: CompletionToastHostingView) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // One above the notch window (`.statusBar + 8`): its full-width envelope
        // covers this strip, and the row must win clicks there.
        level = .statusBar + 9
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        // 见 CompletionFlashWindow:close() 的释放语义在并发 job 的 autorelease
        // pool 里过度释放 → SIGSEGV。换窗只 orderOut + 字典换引用。
        isReleasedWhenClosed = false
        hosting.sizingOptions = []
        contentView = hosting
    }
}

/// SwiftUI for pixels; clicks and hover come from AppKit and are resolved
/// against `CompletionToastLayout` — SwiftUI hover/tap don't reliably fire in
/// a non-activating panel of a never-active app (same as the edge bar).
final class CompletionToastHostingView: NSHostingView<AnyView> {
    /// A left click at a point in this view's (flipped) coordinates.
    var onClick: ((CGPoint) -> Void)?
    /// Whether the cursor is over the row. Exits are checked against the real
    /// cursor before being reported (a rebuilt tracking area under a still
    /// cursor can send a spurious exit), and while inside the cursor is
    /// rechecked every 0.25s — a doubted exit gets no second exit event, so
    /// without the recheck the row could stay "hovered" (timers frozen) forever.
    var onHover: ((Bool) -> Void)?

    var layout = CompletionToastLayout(panelWidth: 0, count: 0) {
        didSet {
            if layout.cardRects != oldValue.cardRects {
                updateTrackingAreas()
            }
        }
    }

    private var area: NSTrackingArea?
    private var hovering = false
    private var recheckTimer: Timer?
    private static let recheckInterval: TimeInterval = 0.25

    /// The hover region: the whole row, gaps included, so moving between
    /// cards is not a leave.
    private var rowRect: CGRect {
        layout.cardRects.reduce(CGRect.null) { $0.union($1) }
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor dynamic required init?(coder: NSCoder) {
        fatalError("not built from a nib")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard layout.cardRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0 else {
            super.mouseDown(with: event)
            return
        }
        onClick?(convert(event.locationInWindow, from: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area {
            removeTrackingArea(area)
        }
        area = nil
        let rect = rowRect
        if !rect.isNull {
            let fresh = NSTrackingArea(
                rect: rect,
                options: [.mouseEnteredAndExited, .activeAlways],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(fresh)
            area = fresh
        }
        // A removed or shrunk area sends no exit; ask the cursor directly.
        report(cursorInRow())
    }

    override func mouseEntered(with _: NSEvent) {
        report(true)
    }

    override func mouseExited(with _: NSEvent) {
        report(cursorInRow())
    }

    /// The panel is going away: stop the recheck (a hidden panel can't be hovered).
    func stopHoverTracking() {
        recheckTimer?.invalidate()
        recheckTimer = nil
        hovering = false
    }

    private func cursorInRow() -> Bool {
        guard let window, !rowRect.isNull else { return false }
        return rowRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func report(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        if inside {
            recheckTimer = Timer
                .scheduledTimer(withTimeInterval: Self.recheckInterval, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.report(self.cursorInRow())
                    }
                }
        } else {
            recheckTimer?.invalidate()
            recheckTimer = nil
        }
        onHover?(inside)
    }
}

/// The toast row's content: cards placed at `CompletionToastLayout` positions.
private struct CompletionToastRowView: View {
    let service: CompletionFlashService
    let panelWidth: CGFloat

    /// 首帧挂载闸门:面板在 toast 到达时才新建(具文窗口修复,见
    /// CompletionFlashWindowController.applyOverlayVisibility),新树挂载时
    /// `toasts` 已非空 —— 直接首渲染终态,入场 transition 不会播放。先以空行
    /// 挂载、下一帧放行。
    @State private var mounted = false

    var body: some View {
        let toasts = mounted ? service.toasts : []
        let layout = CompletionToastLayout(panelWidth: panelWidth, count: toasts.count)
        ZStack(alignment: .topLeading) {
            ForEach(Array(toasts.enumerated()), id: \.element.id) { index, toast in
                let rect = layout.cardRect(at: index)
                CompletionToastView(item: toast.item)
                    .position(x: rect.midX, y: rect.midY)
                    // Scale from the top edge: stays inside the panel (a move
                    // from above would be clipped by the panel's top).
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(duration: NotchConstants.hudAppearDuration, bounce: 0.08), value: mounted)
        .onAppear {
            guard !mounted else { return }
            DispatchQueue.main.async { mounted = true }
        }
    }
}

/// Owns one toast panel per screen, hanging under that screen's notch. Panels
/// exist only while there are toasts, and are rebuilt fresh each time the row
/// (re)appears on a screen — a long-idle window ordered back in can come up
/// with no render surface on a non-main display (see
/// `CompletionFlashWindowController.applyOverlayVisibility`).
///
/// A screen whose notch is open hides its row: the opened panel occupies
/// exactly that spot.
@MainActor
final class CompletionToastWindowController {
    private var panels: [UInt32: CompletionToastPanel] = [:]
    private var hosts: [UInt32: CompletionToastHostingView] = [:]
    private var hoveredScreens: Set<UInt32> = []
    private var hideTask: Task<Void, Never>?
    private var rebuildPending = false
    private let service: CompletionFlashService
    private let coordinator: NotchCoordinator
    private nonisolated(unsafe) var observer: Any?

    private static let panelWidth = CompletionToastLayout.panelWidth(capacity: NotchConstants.completionToastCapacity)
    /// Just the cards (plus the stroke); the transition scales within it.
    private static let panelHeight = CompletionToastLayout.cardHeight + 2

    init(service: CompletionFlashService, coordinator: NotchCoordinator) {
        self.service = service
        self.coordinator = coordinator
        LogService.info("CompletionToastWindowController init", category: "CompletionFlash")
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // L1:屏幕重配的窗口重建推迟一个 runloop turn(崩溃族,见 AGENTS.md)。
            MainActor.assumeIsolated {
                self?.scheduleRebuild()
            }
        }
        observe()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        LogService.info("CompletionToastWindowController deinit", category: "CompletionFlash")
    }

    private func observe() {
        withObservationTracking {
            _ = service.toasts
            _ = coordinator.status
            _ = coordinator.activeScreen
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                observe() // re-arm before applying so no change is missed
                // Window work stays out of the observation Task (see AGENTS.md).
                DispatchQueue.main.async { [weak self] in self?.apply() }
            }
        }
    }

    private func scheduleRebuild() {
        guard !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            rebuildPending = false
            LogService.info("screen parameters changed — rebuilding toast panels", category: "CompletionFlash")
            for id in Array(panels.keys) {
                remove(id)
            }
            apply()
        }
    }

    /// Screens that should show the row right now.
    private func wantedScreens() -> [NSScreen] {
        guard !service.toasts.isEmpty else { return [] }
        let openID = coordinator.status == .opened ? coordinator.activeScreen?.displayID : nil
        return NSScreen.screens.filter { $0.displayID != openID }
    }

    private func apply() {
        let wanted = wantedScreens()
        let wantedIDs = Set(wanted.map(\.displayID))

        if service.toasts.isEmpty {
            // Let the last card's exit transition play before ordering out.
            guard hideTask == nil, !panels.isEmpty else { return }
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(NotchConstants.hudAppearDuration + 0.1))
                guard let self, !Task.isCancelled else { return }
                hideTask = nil
                DispatchQueue.main.async { [self] in
                    guard service.toasts.isEmpty else { return }
                    for id in Array(panels.keys) {
                        remove(id)
                    }
                }
            }
            return
        }
        hideTask?.cancel()
        hideTask = nil

        for id in Array(panels.keys) where !wantedIDs.contains(id) {
            remove(id)
        }
        for screen in wanted {
            let id = screen.displayID
            if panels[id] == nil {
                makePanel(for: screen)
            }
            hosts[id]?.layout = CompletionToastLayout(panelWidth: Self.panelWidth, count: service.toasts.count)
        }
    }

    private func remove(_ id: UInt32) {
        panels[id]?.orderOut(nil)
        hosts[id]?.stopHoverTracking()
        panels[id] = nil
        hosts[id] = nil
        // A hidden panel sends no exit; drop its hover so timers can't stay frozen.
        setHover(false, screen: id)
    }

    private func makePanel(for screen: NSScreen) {
        let id = screen.displayID
        let width = Self.panelWidth
        let host = CompletionToastHostingView(
            rootView: AnyView(CompletionToastRowView(service: service, panelWidth: width))
        )
        host.onClick = { [weak self, weak host] point in
            guard let self, let host else { return }
            handleClick(point, layout: host.layout)
        }
        host.onHover = { [weak self] inside in
            self?.setHover(inside, screen: id)
        }
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - coordinator.notchSize.height - CompletionToastLayout.topGap - Self.panelHeight,
            width: width,
            height: Self.panelHeight
        )
        host.frame = NSRect(origin: .zero, size: frame.size)
        let panel = CompletionToastPanel(frame: frame, hosting: host)
        panels[id] = panel
        hosts[id] = host
        host.layout = CompletionToastLayout(panelWidth: width, count: service.toasts.count)
        panel.orderFrontRegardless()
        LogService.debug("Toast panel created for display \(id)", category: "CompletionFlash")
    }

    private func handleClick(_ point: CGPoint, layout: CompletionToastLayout) {
        switch CompletionToastClick.action(for: layout.hit(point), toasts: service.toasts) {
        case let .dismiss(id):
            service.dismissToast(id: id)
        case let .jump(id, target):
            AppActivator.activate(
                pid: target.hostPID,
                expectedBundleId: target.hostBundleId,
                tabLink: target.tabLink
            )
            service.dismissToast(id: id)
        case let .open(id, bundleID):
            AppActivator.openApp(bundleId: bundleID)
            service.dismissToast(id: id)
        case nil:
            break
        }
    }

    private func setHover(_ inside: Bool, screen id: UInt32) {
        if inside {
            hoveredScreens.insert(id)
        } else {
            hoveredScreens.remove(id)
        }
        service.setToastHover(!hoveredScreens.isEmpty)
    }
}
