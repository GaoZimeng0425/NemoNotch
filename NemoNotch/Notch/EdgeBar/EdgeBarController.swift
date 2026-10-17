import AppKit
import SwiftUI

/// Geometry for the edge bar, in one place (evlat-measured).
enum EdgeBarMetrics {
    static let gutter: CGFloat = 18
    static let corner: CGFloat = 18
    static let flare: CGFloat = 20
    static let bodyMargin: CGFloat = 14
    /// Distance from the window's top to the top of the head (flare + margin).
    static let headTop: CGFloat = flare + bodyMargin
    static let headSize: CGFloat = 34
    static let ringSize: CGFloat = 20
    static let ringSpacing: CGFloat = 10
    static let ringTopGap: CGFloat = 18

    /// Closed body: margins + the head.
    static var closedWidth: CGFloat {
        bodyMargin * 2 + headSize
    }

    /// Open body: room for the names column.
    static var openWidth: CGFloat {
        240
    }

    /// Detail card.
    static let cardWidth: CGFloat = 320
    static let cardGap: CGFloat = 8

    /// Slot pitch and the top of ring `index` (window coords, top-down).
    static var ringPitch: CGFloat {
        ringSize + ringSpacing
    }

    static func ringTop(_ index: Int) -> CGFloat {
        headTop + headSize + ringTopGap + CGFloat(index) * ringPitch
    }

    /// The head block plus one slot per ring — the body between the flares.
    static func bodyLength(slots: Int) -> CGFloat {
        let head = headTop + headSize + headTop
        guard slots > 0 else { return head }
        return head + ringTopGap + CGFloat(slots) * ringSize + CGFloat(slots - 1) * ringSpacing
    }

    /// Full drawn extent (the flares add `2 × flare` at the edge).
    static func drawnLength(slots: Int) -> CGFloat {
        bodyLength(slots: slots) + flare * 2
    }

    /// Body width for the current state.
    static func bodyWidth(isOpen: Bool) -> CGFloat {
        isOpen ? openWidth : closedWidth
    }
}

/// Hover timing, evlat-measured.
enum EdgeBarMotion {
    static let openDelay: TimeInterval = 0.08
    static let closeTolerance: TimeInterval = 0.25
    static let cardDwell: TimeInterval = 0.15
    static let bodyDuration: TimeInterval = 0.24
    static let namesIn = Animation.easeOut(duration: 0.18).delay(0.07)
    static let namesOut = Animation.easeIn(duration: 0.1)
    static let cardIn = Animation.smooth(duration: 0.26)
    static let cardOut = Animation.easeIn(duration: 0.14)
}

/// Owns the edge bar: computes rows from the AI session store, runs the
/// hover state machine (open delay / close tolerance / card dwell), and
/// drives the window. All interaction rides NSView overlays
/// (`BarInteractView`) — SwiftUI discrete gestures never fire in this
/// non-activating panel.
@MainActor
@Observable
final class EdgeBarController: NSObject {
    private(set) var isOpen = false
    private(set) var rows: [EdgeBarRow] = []
    private(set) var overflow = 0
    private(set) var summary = ""
    private(set) var cardRowId: String?

    private let store: AISessionStore
    private let appSettings: AppSettings
    private let aiMonitor: AICLIMonitorService
    private let chatBubble: ChatBubbleController
    private var window: EdgeBarWindow?
    private var hitView: EdgeBarHitView?
    private var started = false
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?

    init(
        store: AISessionStore,
        appSettings: AppSettings,
        aiMonitor: AICLIMonitorService,
        chatBubble: ChatBubbleController
    ) {
        self.store = store
        self.appSettings = appSettings
        self.aiMonitor = aiMonitor
        self.chatBubble = chatBubble
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        observe()
        show()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.redock() }
        }
    }

    // MARK: - Store observation

    private func observe() {
        withObservationTracking {
            _ = store.sortedSessions.map { "\($0.id):\($0.phase):\($0.lastEventTime)" }
            _ = appSettings.aiStatusFabEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
                self?.refresh()
            }
        }
        refresh()
    }

    private func refresh() {
        guard appSettings.aiStatusFabEnabled else {
            window?.orderOut(nil)
            return
        }
        // Toggling the setting back on must re-order the bar in (start() only
        // shows once; a settings-off cycle ordered it out above).
        show()
        let content = EdgeBarModel.content(of: store.sortedSessions)
        rows = content.rows
        overflow = content.overflow
        summary = content.summary
        // A hovered/selected row that left the store takes its card with it.
        if let cardRowId, !rows.contains(where: { $0.id == cardRowId }) {
            self.cardRowId = nil
        }
        updateHitRects()
    }

    // MARK: - Window

    private func show() {
        guard window == nil else {
            window?.orderFrontRegardless()
            return
        }
        guard let screen = NSScreen.main else { return }
        let w = EdgeBarWindow(visibleFrame: screen.visibleFrame)
        let hit = EdgeBarHitView(frame: NSRect(origin: .zero, size: w.frame.size))
        hit.wantsLayer = true
        hit.layer?.backgroundColor = NSColor.clear.cgColor
        let hosting = NSHostingView(
            rootView: EdgeBarView()
                .environment(self)
                .environment(store)
                .environment(appSettings)
        )
        hosting.frame = hit.bounds
        hosting.autoresizingMask = [.width, .height]
        hit.addSubview(hosting)
        w.contentView = hit
        hitView = hit
        window = w
        w.orderFrontRegardless()
        updateHitRects()
    }

    private func redock() {
        guard let window, let screen = NSScreen.main else { return }
        window.setFrame(NSRect(
            origin: screen.visibleFrame.origin,
            size: window.frame.size
        ), display: true)
    }

    /// Store read-through for the view (card content needs session detail
    /// beyond the row: current tool, tokens).
    func session(_ id: String) -> AISessionState? {
        store.get(id)
    }

    /// The head's drag moves the window.
    func beginWindowDrag(_ event: NSEvent) {
        window?.performDrag(with: event)
    }

    /// The rects events may land in (content-view coords, top-down): the bar
    /// body, and the detail card while it is up. Everything else in the
    /// envelope passes clicks through to whatever is behind.
    private func updateHitRects() {
        guard let hitView else { return }
        let slots = min(rows.count, EdgeBarModel.visibleCap) + (overflow > 0 ? 1 : 0)
        var rects = [CGRect(
            x: EdgeBarMetrics.gutter,
            y: EdgeBarMetrics.gutter,
            width: EdgeBarMetrics.bodyWidth(isOpen: isOpen),
            height: EdgeBarMetrics.drawnLength(slots: slots)
        )]
        if cardRowId != nil {
            rects.append(CGRect(
                x: EdgeBarMetrics.gutter + EdgeBarMetrics.bodyWidth(isOpen: true) + EdgeBarMetrics.cardGap - 4,
                y: 0,
                width: EdgeBarMetrics.cardWidth + 24,
                height: 460
            ))
        }
        hitView.hitRects = rects
    }

    // MARK: - Hover state machine (NSView callbacks)

    /// The pointer entered/left the bar body.
    func bodyHover(_ inside: Bool) {
        if inside {
            closeTask?.cancel()
            closeTask = nil
            guard !isOpen else { return }
            openTask?.cancel()
            openTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(EdgeBarMotion.openDelay))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: EdgeBarMotion.bodyDuration)) { self?.isOpen = true }
                self?.updateHitRects()
            }
        } else {
            openTask?.cancel()
            openTask = nil
            guard isOpen else { return }
            closeTask?.cancel()
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(EdgeBarMotion.closeTolerance))
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: EdgeBarMotion.bodyDuration)) { self?.isOpen = false }
                withAnimation(EdgeBarMotion.cardOut) { self?.cardRowId = nil }
                self?.updateHitRects()
            }
        }
    }

    /// The pointer entered/left a session row (open list). Dwelling brings up
    /// the detail card; moving between rows re-dwells.
    func rowHover(_ id: String?, inside: Bool) {
        dwellTask?.cancel()
        dwellTask = nil
        guard inside, let id else {
            withAnimation(EdgeBarMotion.cardOut) { cardRowId = nil }
            updateHitRects()
            return
        }
        guard id != cardRowId else { return }
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(EdgeBarMotion.cardDwell))
            guard !Task.isCancelled else { return }
            withAnimation(EdgeBarMotion.cardIn) { self?.cardRowId = id }
            self?.updateHitRects()
        }
    }

    /// Head tap: open the chat bubble (evlat's mascot click).
    func headTapped() {
        chatBubble.show()
    }

    // MARK: - Card actions

    func jump(to row: EdgeBarRow) {
        guard let session = store.get(row.id) else { return }
        AppActivator.activate(
            pid: session.launchingAppPID,
            expectedBundleId: session.launchingAppBundleId,
            tabLink: session.tabLinkURL
        )
    }

    func respondToPermission(sessionId: String, approved: Bool) {
        aiMonitor.respondToPermission(sessionId: sessionId, approved: approved)
    }
}
