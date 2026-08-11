import SwiftUI

/// Borderless, transparent, click-through window covering one full screen.
/// Hosts the edge-glow overlay. Sits at the notch level and joins all Spaces
/// so the glow shows over fullscreen apps too.
final class CompletionFlashWindow: NSWindow {
    init(rect: NSRect) {
        super.init(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar + 8
        ignoresMouseEvents = true
        isMovable = false
        collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// Owns one `CompletionFlashWindow` per connected screen and keeps them in
/// sync with display changes. All windows share the same `CompletionFlashService`,
/// so a single completion flashes every screen at once.
@MainActor
final class CompletionFlashWindowController {
    private var windows: [UInt32: CompletionFlashWindow] = [:]
    private let service: CompletionFlashService
    private nonisolated(unsafe) var observer: Any?

    init(service: CompletionFlashService) {
        self.service = service
        LogService.info("CompletionFlashWindowController init", category: "CompletionFlash")
        rebuild()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        observeOverlayVisibility()
    }

    /// Keep the windows on screen only while there is something to show.
    ///
    /// These are one full-screen window per display (5.2MP across two displays
    /// here) hosting `.blendMode(.screen)` content. AppKit asks every *visible*
    /// window whether it needs to re-layout on each display cycle — the pass is
    /// driven by the window being on screen, not by whether its content changed
    /// or is even opaque. They used to be `orderFrontRegardless()`'d at creation
    /// and never ordered out, so that cost was permanent.
    ///
    /// The window therefore appears one runloop turn after the flash starts
    /// (this observation lands via a `Task`). Harmless in practice: the glow
    /// eases in from zero over `completionFlashRise`, so the frame that gets
    /// missed is the fully-transparent one.
    private func observeOverlayVisibility() {
        withObservationTracking {
            _ = service.overlayVisible
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                observeOverlayVisibility() // re-arm before applying so no change is missed
                applyOverlayVisibility()
            }
        }
    }

    private func applyOverlayVisibility() {
        let visible = service.overlayVisible
        for window in windows.values {
            if visible {
                window.orderFrontRegardless()
            } else {
                window.orderOut(nil)
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        LogService.info("CompletionFlashWindowController deinit", category: "CompletionFlash")
    }

    private func rebuild() {
        let currentIDs = Set(NSScreen.screens.map(\.displayID))
        for (id, window) in windows where !currentIDs.contains(id) {
            window.orderOut(nil)
            window.close()
            windows.removeValue(forKey: id)
            LogService.debug("CompletionFlash window removed for display \(id)", category: "CompletionFlash")
        }
        for screen in NSScreen.screens {
            let id = screen.displayID
            if let existing = windows[id] {
                existing.setFrame(screen.frame, display: true)
            } else {
                windows[id] = makeWindow(for: screen)
                LogService.debug("CompletionFlash window added for display \(id)", category: "CompletionFlash")
            }
        }
    }

    /// The single screen that renders the toast capsule: the built-in display
    /// when present (matching `NotchView.isHUDScreen`), else the first screen.
    private static func toastScreenID() -> UInt32? {
        let target = NSScreen.screens.first(where: { $0.isBuiltInDisplay }) ?? NSScreen.screens.first
        return target?.displayID
    }

    private func makeWindow(for screen: NSScreen) -> CompletionFlashWindow {
        let window = CompletionFlashWindow(rect: screen.frame)
        let showsToast = screen.displayID == Self.toastScreenID()
        let host = NSHostingView(rootView: CompletionFlashView(service: service, showsToast: showsToast))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        window.contentView = host
        // Windows rebuilt mid-flash (display change) must match the current
        // state rather than always coming up on screen.
        if service.overlayVisible {
            window.orderFrontRegardless()
        }
        return window
    }
}
