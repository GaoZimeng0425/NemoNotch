import AppKit
import SwiftUI

/// Drives the "open System Settings and drag the app in" authorization guide.
///
/// Sequence:
/// 1. Open the pane's deep link.
/// 2. Poll the Window Server for the System Settings window frame (no
///    Accessibility grant required — see `SystemSettingsWindowTracker`).
/// 3. Park the floating guide next to that window and keep it pinned as the
///    user moves or resizes it.
/// 4. Poll the grant; on success show a confirmation, then retire the guide.
/// 5. Retire automatically when System Settings closes, on ESC, or on timeout.
@MainActor
final class PermissionFlowController {
    static let shared = PermissionFlowController()

    private enum Constants {
        /// How often the guide re-reads the System Settings window frame.
        static let followInterval: TimeInterval = 0.2
        /// How often the grant is re-checked.
        static let grantInterval: TimeInterval = 1.0
        /// Bootstrap cadence while waiting for System Settings to launch.
        static let bootstrapInterval: TimeInterval = 0.15
        /// Give up waiting for the window and show the guide at the fallback spot.
        static let bootstrapAttempts = 30
        /// Consecutive missed window reads before treating Settings as closed.
        /// Generous enough to ride out a Spaces switch or a minimize.
        static let missedFramesBeforeClose = 15
        /// Hard stop so a forgotten guide can't sit on screen indefinitely.
        static let timeout: TimeInterval = 180
        /// Gap between the System Settings window and the guide.
        static let gap: CGFloat = 14
        /// How long the success state stays visible before the guide retires.
        static let successLinger: TimeInterval = 1.6
    }

    private var panel: PermissionDragPanel?
    private var hosting: NSHostingController<PermissionDragPanelView>?
    private var pane: PermissionPane?
    private var state: PermissionGuideState = .waiting

    private var followTimer: Timer?
    private var grantTimer: Timer?
    private var bootstrapTimer: Timer?
    private var terminateObserver: NSObjectProtocol?
    private var successWorkItem: DispatchWorkItem?

    private var missedFrames = 0
    private var lastFrame: CGRect?
    private var startedAt = Date()

    private init() {}

    // MARK: - Public

    /// Opens the pane and shows the drag guide. No-op when the permission is
    /// already granted — there is nothing left to guide.
    func start(pane: PermissionPane) {
        if pane.isGranted?() == true {
            LogService.info("\(pane) already granted — guide skipped", category: "PermissionFlow")
            return
        }

        // Only one guide at a time: overlapping panels fight for the same
        // anchor and end up more confusing than helpful.
        retire()

        self.pane = pane
        state = .waiting
        missedFrames = 0
        lastFrame = nil
        startedAt = Date()

        LogService.info("opening \(pane)", category: "PermissionFlow")
        NSWorkspace.shared.open(pane.settingsURL)
        observeTermination()
        beginBootstrap()
    }

    /// Tears the guide down immediately.
    func retire() {
        followTimer?.invalidate(); followTimer = nil
        grantTimer?.invalidate(); grantTimer = nil
        bootstrapTimer?.invalidate(); bootstrapTimer = nil
        successWorkItem?.cancel(); successWorkItem = nil
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
            self.terminateObserver = nil
        }
        pane = nil
        lastFrame = nil
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
    }

    // MARK: - Bootstrap

    private func beginBootstrap() {
        var attempts = 0
        bootstrapTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.bootstrapInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                attempts += 1
                if let frame = SystemSettingsWindowTracker.frontmostWindowFrame() {
                    self.invalidateBootstrap()
                    self.showPanel(settingsFrame: frame)
                    return
                }
                // Either System Settings is still launching, or it was already
                // open on another pane and hasn't navigated yet. Show the guide
                // at the fallback spot; the follow timer snaps it into place as
                // soon as a window appears.
                if attempts >= Constants.bootstrapAttempts {
                    self.invalidateBootstrap()
                    self.showPanel(settingsFrame: nil)
                }
            }
        }
    }

    private func invalidateBootstrap() {
        bootstrapTimer?.invalidate()
        bootstrapTimer = nil
    }

    private func invalidateFollow() {
        followTimer?.invalidate()
        followTimer = nil
    }

    private func invalidateGrant() {
        grantTimer?.invalidate()
        grantTimer = nil
    }

    // MARK: - Panel

    private func showPanel(settingsFrame: CGRect?) {
        guard let pane else { return }

        let controller = NSHostingController(rootView: makeRoot())
        let panel = PermissionDragPanel(
            contentRect: NSRect(origin: .zero, size: controller.view.fittingSize)
        )
        panel.contentViewController = controller
        panel.setContentSize(controller.view.fittingSize)

        self.panel = panel
        self.hosting = controller
        panel.onEscape = { [weak self] in
            LogService.info("dismissed with ESC", category: "PermissionFlow")
            self?.retire()
        }

        position(panel, relativeTo: settingsFrame)
        panel.makeKeyAndOrderFront(nil)
        LogService.info(
            "guide shown for \(pane) at \(NSStringFromRect(panel.frame))",
            category: "PermissionFlow"
        )

        startFollowing()
        startGrantPolling()
    }

    private func makeRoot() -> PermissionDragPanelView {
        PermissionDragPanelView(
            pane: pane ?? .accessibility,
            appName: Self.appName,
            appIcon: Self.appIcon,
            appURL: Bundle.main.bundleURL,
            state: state,
            onClose: { [weak self] in self?.retire() }
        )
    }

    /// Re-render the panel for the current state by swapping the hosting root.
    private func refresh() {
        guard let hosting, let panel else { return }
        hosting.rootView = makeRoot()
        var frame = panel.frame
        let size = hosting.view.fittingSize
        // Resize from the top edge down so the panel doesn't drift.
        frame.origin.y += frame.size.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true)
    }

    private static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "NemoNotch"
    }

    private static var appIcon: NSImage {
        NSApp.applicationIconImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }

    // MARK: - Positioning

    private func position(_ panel: NSPanel, relativeTo settingsFrame: CGRect?) {
        let size = panel.frame.size

        guard let frame = settingsFrame else {
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 24
            ))
            return
        }

        let screen = NSScreen.screens.first { $0.frame.contains(frame.origin) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

        // Directly below the window is preferred — it never covers the list
        // the user has to drop onto. Sides are the fallback when the window
        // leaves no vertical room.
        let candidates = [
            CGPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - Constants.gap),
            CGPoint(x: frame.maxX + Constants.gap, y: frame.midY - size.height / 2),
            CGPoint(x: frame.minX - size.width - Constants.gap, y: frame.midY - size.height / 2),
        ]

        if let origin = candidates.first(where: { fits($0, size: size, in: visible) }) {
            panel.setFrameOrigin(origin)
            return
        }

        // Nothing fits cleanly — clamp inside the visible area so the guide
        // never lands off the display edge.
        panel.setFrameOrigin(NSPoint(
            x: min(max(frame.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8),
            y: visible.minY + 8
        ))
    }

    private func fits(_ origin: CGPoint, size: CGSize, in visible: CGRect) -> Bool {
        visible.contains(CGRect(origin: origin, size: size))
    }

    // MARK: - Timers

    private func startFollowing() {
        followTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.followInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else {
                    self?.invalidateFollow()
                    return
                }

                if Date().timeIntervalSince(self.startedAt) >= Constants.timeout {
                    LogService.info("timed out", category: "PermissionFlow")
                    self.retire()
                    return
                }

                if let frame = SystemSettingsWindowTracker.frontmostWindowFrame() {
                    self.missedFrames = 0
                    if frame != self.lastFrame {
                        self.lastFrame = frame
                        self.position(panel, relativeTo: frame)
                    }
                } else {
                    self.missedFrames += 1
                    if self.missedFrames >= Constants.missedFramesBeforeClose {
                        LogService.info("System Settings window gone", category: "PermissionFlow")
                        self.retire()
                    }
                }
            }
        }
    }

    private func startGrantPolling() {
        guard let pane, pane.isGranted != nil else {
            // No public preflight for this service, so success can't be
            // auto-detected: the guide waits for Settings to close or for the
            // user to dismiss it.
            return
        }
        grantTimer = Timer.scheduledTimer(
            withTimeInterval: Constants.grantInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let pane = self.pane, let check = pane.isGranted else {
                    self?.invalidateGrant()
                    return
                }
                // Resolved inside the isolated closure so the non-Sendable
                // closure isn't captured by the timer's @Sendable block.
                guard check() else { return }
                self.invalidateGrant()
                LogService.info("grant detected", category: "PermissionFlow")
                self.state = .granted
                self.refresh()
                let work = DispatchWorkItem { [weak self] in self?.retire() }
                self.successWorkItem = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + Constants.successLinger,
                    execute: work
                )
            }
        }
    }

    private func observeTermination() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                  app.bundleIdentifier == SystemSettingsWindowTracker.bundleIdentifier
            else { return }
            MainActor.assumeIsolated { self?.retire() }
        }
    }
}
