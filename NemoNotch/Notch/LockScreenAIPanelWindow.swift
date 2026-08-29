import AppKit
import SkyLightWindow
import SwiftUI

/// Borderless display-only window that renders the AI activity panel on top of
/// the macOS lock screen.
///
/// Two cooperating mechanisms, matching the technique Atoll (reference
/// project) validated: the window level is set to `CGShieldingWindowLevel()`,
/// and the window is *delegated* once via `SkyLightOperator` (MIT-licensed
/// package), which moves it into a private SkyLight space pinned at the
/// notification-center-at-screen-lock level — the only zone where third-party
/// content survives above the loginwindow shield. Delegation is one-way per
/// window; the window must stay alive afterwards (order out to hide, never
/// release) or the next delegation/ordering cycle can crash the WindowServer
/// connection.
final class LockScreenAIPanelWindow: NSWindow {
    /// Fixed canvas the card lives in. Sized once for the maximum row count;
    /// fewer sessions just leave transparent space below the card (the window
    /// ignores mouse events, so the remainder is truly inert).
    static let canvasSize = CGSize(width: 340, height: 330)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.canvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // Display-only: the lock screen belongs to the system, the panel never
        // intercepts clicks (approval happens in the CLI's own TUI anyway).
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Card hangs downward from the screen's vertical midpoint — the region
    /// macOS leaves empty between the big clock (top) and the widget column
    /// (bottom) on the lock screen.
    static func frame(for screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        let originX = screenFrame.midX - canvasSize.width / 2
        let originY = screenFrame.midY - canvasSize.height
        return NSRect(origin: CGPoint(x: originX, y: originY), size: canvasSize)
    }
}

@MainActor
final class LockScreenAIPanelController: NSObject {
    @ObservationIgnored private var window: LockScreenAIPanelWindow?
    @ObservationIgnored private var hasDelegated = false
    @ObservationIgnored private var ensureTask: Task<Void, Never>?
    @ObservationIgnored private let store: AISessionStore
    @ObservationIgnored private let appSettings: AppSettings
    @ObservationIgnored private let monitor: LockScreenMonitor

    init(store: AISessionStore, appSettings: AppSettings, monitor: LockScreenMonitor) {
        self.store = store
        self.appSettings = appSettings
        self.monitor = monitor
        super.init()
        LogService.info("LockScreenAIPanelController init", category: "LockScreenAIPanel")
        observe()
    }

    deinit {
        MainActor.assumeIsolated {
            ensureTask?.cancel()
        }
    }

    // MARK: - Observation

    private func observe() {
        withObservationTracking {
            _ = store.sortedSessions.map { ($0.id, $0.phase) }
            _ = appSettings.lockScreenAIPanelEnabled
            _ = monitor.isLocked
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observe() // re-arm before evaluating
                self.evaluate()
            }
        }
    }

    private func evaluate() {
        let sessions = store.sortedSessions
        guard LockScreenAIPanelModel.shouldShow(
            sessions: sessions,
            isLocked: monitor.isLocked,
            enabled: appSettings.lockScreenAIPanelEnabled
        ) else {
            hide()
            return
        }
        show()
    }

    // MARK: - Show / hide

    private func show() {
        ensureTask?.cancel()
        guard window == nil || window?.isVisible != true else { return }

        let w = window ?? LockScreenAIPanelWindow()
        window = w

        let hosting = NSHostingView(
            rootView: LockScreenAIPanelView()
                .environment(store)
                .environment(appSettings)
        )
        hosting.frame = NSRect(origin: .zero, size: w.frame.size)
        hosting.autoresizingMask = [.width, .height]
        w.contentView = hosting

        w.setFrame(LockScreenAIPanelWindow.frame(for: preferredScreen()), display: true)

        if !hasDelegated {
            SkyLightOperator.shared.delegateWindow(w)
            hasDelegated = true
        }
        w.orderFrontRegardless()

        // Mid-lock self-check: some system transitions drop the panel while
        // the session is still locked (Atoll saw the same); re-present.
        ensureTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(LockScreenMonitor.pollInterval))
                guard let self, !Task.isCancelled else { return }
                guard self.monitor.isLocked else { return }
                if self.window?.isVisible != true || self.window?.contentView == nil {
                    LogService.info("lock screen panel vanished while locked, re-presenting", category: "LockScreenAIPanel")
                    self.show()
                    return
                }
            }
        }

        LogService.info("lock screen panel shown", category: "LockScreenAIPanel")
    }

    private func hide() {
        ensureTask?.cancel()
        ensureTask = nil
        guard let w = window, w.isVisible || w.contentView != nil else { return }
        // Keep the window alive; only detach content and order out. Releasing
        // a delegated window is what crashes SkyLight (Atoll's hard-won note),
        // and contentView = nil also unmounts the SwiftUI tree so nothing
        // ticks while unlocked.
        w.contentView = nil
        w.orderOut(nil)
        LogService.info("lock screen panel hidden", category: "LockScreenAIPanel")
    }

    /// The lock screen lives on the built-in display; fall back to the main
    /// screen for Macs without a notch display.
    private func preferredScreen() -> NSScreen {
        NSScreen.screens.first(where: { $0.isBuiltInDisplay })
            ?? NSScreen.screens.first(where: { $0 == NSScreen.main })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
