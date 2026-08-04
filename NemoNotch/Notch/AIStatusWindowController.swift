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
        // Drive the SwiftUI morph via a value-bound spring — mirrors
        // `NotchCoordinator.notchClose`. The window is NOT resized and the
        // hosting root is NOT rebuilt (both were the source of the flicker);
        // the capsule↔panel transition is fully SwiftUI-internal.
        withAnimation(.spring(duration: NotchConstants.aiStatusFabCloseSpringDuration)) {
            isExpanded = false
        }
    }

    private func expand() {
        withAnimation(.spring(duration: NotchConstants.aiStatusFabOpenSpringDuration, bounce: 0.1)) {
            isExpanded = true
        }
    }

    /// Entry point for drag gestures (capsule body + expanded header). The
    /// `DragHandleView` (an NSViewRepresentable) in AIStatusFABView forwards its
    /// `mouseDown` event here so AppKit can run its standard window-drag loop.
    func beginWindowDrag(with event: NSEvent) {
        window?.performDrag(with: event)
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
            // Wrap the hosting view in a PassThroughView so empty canvas regions
            // click through to whatever is behind (mirrors NotchWindow). `isBlocking`
            // stays true: hitTest returns the SwiftUI subview for points that land on
            // interactive content, and nil for the transparent canvas.
            let passThrough = PassThroughView(frame: NSRect(origin: .zero, size: w.frame.size))
            passThrough.isBlocking = true
            host.view.frame = passThrough.bounds
            passThrough.addSubview(host.view)
            w.contentView = passThrough
        }
        // Fixed canvas: do NOT call setContentSize(fittingSize) here — the window
        // was created at the full panel footprint and never resizes on toggle.
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
