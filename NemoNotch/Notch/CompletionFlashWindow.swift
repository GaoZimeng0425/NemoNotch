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
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func rebuild() {
        let currentIDs = Set(NSScreen.screens.map(\.displayID))
        for (id, window) in windows where !currentIDs.contains(id) {
            window.orderOut(nil)
            windows.removeValue(forKey: id)
        }
        for screen in NSScreen.screens {
            let id = screen.displayID
            if let existing = windows[id] {
                existing.setFrame(screen.frame, display: true)
            } else {
                windows[id] = makeWindow(for: screen)
            }
        }
    }

    private func makeWindow(for screen: NSScreen) -> CompletionFlashWindow {
        let window = CompletionFlashWindow(rect: screen.frame)
        let host = NSHostingView(rootView: CompletionFlashView(service: service))
        host.frame = NSRect(origin: .zero, size: screen.frame.size)
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        window.contentView = host
        window.orderFrontRegardless()
        return window
    }
}
