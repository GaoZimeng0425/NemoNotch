import AppKit
import SwiftUI

/// The chat bubble: a small non-activating panel that runs your own
/// `claude` CLI one turn at a time (evlat's chat balloon, v1 scope). The
/// spawned CLI fires the user's installed hooks, so the session lands in
/// `AISessionStore` like any Claude session — the notch sees it, its
/// permission prompts flow through the held-connection machinery, and the
/// bubble's answer buttons reuse `respondToPermission`.
@MainActor
@Observable
final class ChatBubbleController: NSObject, NSWindowDelegate {
    private(set) var isVisible = false

    struct BubbleMessage: Identifiable, Equatable {
        enum Role: Equatable { case user, assistant }
        let id: UUID
        var role: Role
        var text: String
        var isStreaming: Bool

        init(role: Role, text: String, isStreaming: Bool = false) {
            id = UUID()
            self.role = role
            self.text = text
            self.isStreaming = isStreaming
        }
    }

    private(set) var messages: [BubbleMessage] = []
    /// Tool currently running in the in-flight turn (badge in the view).
    private(set) var runningTool: String?
    private(set) var isTurnRunning = false

    /// The claude session id — fixed for the bubble's lifetime so hooks,
    /// transcript parsing and --resume all land on one session.
    private(set) var claudeSessionId: String = UserDefaults.standard.string(forKey: "chatBubbleSessionId") ?? UUID()
        .uuidString

    private static let sessionIdKey = "chatBubbleSessionId"
    private let store: AISessionStore
    private let aiMonitor: AICLIMonitorService
    private let runner = ChatTurnRunner()
    private var window: NSPanel?
    /// True after the first completed turn — later turns --resume.
    private var hasCompletedTurn = false

    init(store: AISessionStore, aiMonitor: AICLIMonitorService) {
        self.store = store
        self.aiMonitor = aiMonitor
        super.init()
        LogService.info("ChatBubbleController init", category: "ChatBubble")
    }

    // MARK: - Window

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }
        guard let window else { return }
        window.isVisible ? window.orderFrontRegardless() : window.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    private func makeWindow() -> NSPanel? {
        let panel = ChatBubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 460),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ChatBubbleView()
            .environment(self)
            .environment(store))
        // Top-right, below the menu bar notch zone — the FAB's neighborhood.
        if let screen = NSScreen.main {
            let frame = panel.frame
            let margin: CGFloat = 16
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.maxX - frame.width - margin,
                y: screen.visibleFrame.maxY - frame.height - margin
            ))
        }
        return panel
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.isVisible = false }
    }

    // MARK: - Turns

    func send(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isTurnRunning else { return }
        messages.append(BubbleMessage(role: .user, text: prompt))
        isTurnRunning = true
        runner.run(
            prompt: prompt,
            sessionId: claudeSessionId,
            resume: hasCompletedTurn,
            handlers: ChatTurnRunner.Handlers(
                onTextDelta: { [weak self] full in
                    self?.updateStreamingMessage(full)
                },
                onNewMessage: { [weak self] in
                    self?.messages.append(BubbleMessage(role: .assistant, text: "", isStreaming: true))
                },
                onToolStarted: { [weak self] name in
                    self?.runningTool = name
                },
                onTurnCompleted: { [weak self] result, isError in
                    self?.finishTurn(result: result, isError: isError)
                }
            )
        )
    }

    func stopTurn() {
        runner.stop()
    }

    private func updateStreamingMessage(_ full: String) {
        runningTool = nil
        guard let last = messages.last, last.isStreaming else { return }
        messages[messages.count - 1].text = full
    }

    private func finishTurn(result: String?, isError: Bool) {
        runningTool = nil
        isTurnRunning = false
        // A streamed message is already on screen; only a turn with no text
        // (errors, empty results) appends its result directly.
        if !(messages.last?.isStreaming ?? false), let result, !result.isEmpty {
            messages.append(BubbleMessage(role: .assistant, text: result))
        } else if let last = messages.last, last.isStreaming {
            messages[messages.count - 1].isStreaming = false
        }
        if isError {
            LogService.warn("Chat turn ended with error: \(result ?? "?")", category: "ChatBubble")
        } else {
            LogService.info("Chat turn completed", category: "ChatBubble")
        }
        hasCompletedTurn = true
        UserDefaults.standard.set(claudeSessionId, forKey: Self.sessionIdKey)
    }

    /// Permission answer for the bubble's own session — same route as the
    /// notch card and the FAB hover card.
    func respondToPermission(approved: Bool) {
        aiMonitor.respondToPermission(sessionId: claudeSessionId, approved: approved)
    }
}

/// Borderless panel that can take keyboard input (the Spotlight pattern: the
/// panel becomes key while NemoNotch stays inactive).
final class ChatBubblePanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
