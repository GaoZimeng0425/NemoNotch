import AppKit
import SwiftUI

@MainActor
@Observable
final class AIStatusWindowController: NSObject {
    private(set) var isExpanded = false

    @ObservationIgnored private var window: AIStatusWindow?
    @ObservationIgnored private var hostingController: NSHostingController<AnyView>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private let store: AISessionStore
    @ObservationIgnored private let appSettings: AppSettings

    init(store: AISessionStore, appSettings: AppSettings) {
        self.store = store
        self.appSettings = appSettings
        super.init()
        LogService.info("AIStatusWindowController init", category: "AIStatusFAB")
        observe()
    }

    deinit {
        MainActor.assumeIsolated { hideTask?.cancel() }
    }

    // MARK: - Public (called by the SwiftUI view)

    func toggleExpanded() {
        if isExpanded { collapse() } else { expand() }
    }

    func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        // Collapsed capsule is dragged via its background (the whole capsule is
        // the drag handle); re-enable background-drag for that state.
        window?.isMovableByWindowBackground = true
        rehostAndResize()
    }

    private func expand() {
        isExpanded = true
        // In expanded state the list rows must not start a window drag, so the
        // background can no longer be the drag handle. Dragging moves to the
        // header (see `DragHandleView` in AIStatusFABView, which calls
        // `beginWindowDrag`).
        window?.isMovableByWindowBackground = false
        rehostAndResize()
    }

    /// Entry point for the header drag gesture (expanded state). The header's
    /// `DragHandleView` (an NSViewRepresentable) forwards its `mouseDown` event
    /// here so AppKit can run its standard window-drag tracking loop.
    func beginWindowDrag(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// Rebuild the hosting root (so the view swaps capsule↔panel) and resize
    /// the window to fit, keeping the top-right anchor stable as the size
    /// changes. Animated via `setFrame(..., animate: true)`.
    private func rehostAndResize() {
        guard let w = window, let host = hostingController else { return }
        host.rootView = AnyView(
            AIStatusFABView()
                .environment(store)
                .environment(appSettings)
                .environment(\.aiStatusController, self)
        )
        let fitting = host.view.fittingSize
        // Keep the top-right anchor stable as the size changes.
        let current = w.frame
        let origin = CGPoint(
            x: current.maxX - fitting.width,
            y: current.maxY - fitting.height
        )
        w.setFrame(CGRect(origin: origin, size: fitting), display: true, animate: true)
    }

    // MARK: - Observation + show/hide

    private var workingCount: Int {
        store.sortedSessions.filter { $0.status == .working }.count
    }

    private func observe() {
        withObservationTracking {
            _ = store.sortedSessions.map { ($0.id, $0.status) }
            _ = appSettings.aiStatusFabEnabled
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe() // re-arm before evaluating
                self.evaluateVisibility()
            }
        }
    }

    private func evaluateVisibility() {
        guard appSettings.aiStatusFabEnabled else {
            hide(immediate: true)
            return
        }
        if workingCount > 0 {
            show()
        } else if !isExpanded {
            // Preserve the user's expand intent — never auto-hide the panel.
            scheduleHide()
        }
    }

    private func show() {
        hideTask?.cancel()
        hideTask = nil
        guard window == nil || !window!.isVisible else { return }
        let w = window ?? AIStatusWindow()
        window = w
        if hostingController == nil {
            let host = NSHostingController(
                rootView: AnyView(
                    AIStatusFABView()
                        .environment(store)
                        .environment(appSettings)
                        .environment(\.aiStatusController, self)
                )
            )
            host.view.wantsLayer = true
            host.view.layer?.backgroundColor = NSColor.clear.cgColor
            hostingController = host
            w.contentViewController = host
        }
        w.setContentSize(hostingController!.view.fittingSize)
        // applyPosition reads w.frame.size to clamp into visibleFrame, so it
        // MUST run after setContentSize (otherwise it sees the stale 10x10 init
        // rect on first show after restart).
        applyPosition(to: w)
        w.delegate = self
        w.alphaValue = 0
        w.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = NotchConstants.aiStatusFabFadeDuration
            w.animator().alphaValue = 1
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NotchConstants.aiStatusFabHideDelay))
            guard let self, !Task.isCancelled else { return }
            self.hide(immediate: false)
        }
    }

    private func hide(immediate: Bool) {
        hideTask?.cancel()
        // Defensive: any hide path (idle timer OR the settings-toggle forced
        // hide) must reset isExpanded so the next show() renders the capsule,
        // not a stale panel. Pairs with the !isExpanded gate in
        // evaluateVisibility.
        isExpanded = false
        window?.isMovableByWindowBackground = true
        guard let w = window else { return }
        if immediate {
            w.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NotchConstants.aiStatusFabFadeDuration
            w.animator().alphaValue = 0
        }, completionHandler: { [weak w] in
            w?.orderOut(nil)
        })
    }

    // MARK: - Position persistence

    private func applyPosition(to w: NSWindow) {
        // Only set position on first show; afterwards the window keeps its frame
        // (user may have dragged it).
        if w.frame.origin != .zero { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = w.frame.size
        var origin = restoreOrigin()
        // Clamp into the visible frame (slide, keep user's axis preference).
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        // First-ever launch default: top-right of the main screen.
        if origin == .zero {
            origin = CGPoint(
                x: visible.maxX - size.width - NotchConstants.aiStatusFabEdgeMargin,
                y: visible.maxY - size.height - NotchConstants.aiStatusFabEdgeMargin
            )
        }
        w.setFrame(CGRect(origin: origin, size: size), display: false)
    }

    private func restoreOrigin() -> CGPoint {
        guard let data = UserDefaults.standard.data(forKey: AppSettings.aiStatusFabPositionKey),
              let point = try? JSONDecoder().decode(CGPoint.self, from: data) else {
            return .zero
        }
        return point
    }

    /// Called by the window delegate when the user finishes dragging.
    func persistPosition(_ origin: CGPoint) {
        guard let data = try? JSONEncoder().encode(origin) else { return }
        UserDefaults.standard.set(data, forKey: AppSettings.aiStatusFabPositionKey)
    }
}

extension AIStatusWindowController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        persistPosition(w.frame.origin)
    }
}
