import AppKit
import SwiftUI

/// Owns the edge bar: folds the AI session store into rows, runs hover
/// (`EdgeBarHoverIntent`) and row selection (`EdgeBarRowSwitch`), and
/// routes every pointer event by geometry (`EdgeBarMetrics`). The view only
/// draws what this holds; it takes no events of its own.
@MainActor
@Observable
final class EdgeBarController: NSObject {
    /// The card's buttons, resolved by their drawn frames.
    enum CardButton: Hashable {
        case allow, deny, jump
    }

    private(set) var isOpen = false
    private(set) var content: EdgeBarModel.Content = .empty
    /// The open body's width, measured from the rows' text.
    private(set) var openWidth: CGFloat = EdgeBarMetrics.barWidth
    /// The usage block's lines (providers with a readable quota).
    private(set) var usageLines: [EdgeBarUsageLine] = []
    /// The row under the cursor (a faint ground at once, before its card).
    private(set) var hoveredRow: String?
    /// The row whose card is up.
    private(set) var selectedRow: String?
    /// The selected row's slot; kept after deselect so a leaving card fades
    /// where it was.
    private(set) var cardSlot = 0
    private(set) var scrollOffset: CGFloat = 0
    private(set) var isOverHead = false
    private(set) var hoveredButton: CardButton?
    private(set) var pressedButton: CardButton?
    /// The beat counter: runs only while a drawn ring is waiting.
    private(set) var beat = 0
    /// Where the bar's top sits in the canvas, and the canvas height — set
    /// by the dock cycle so view and window never disagree.
    private(set) var barTop: CGFloat = 200
    private(set) var canvasHeight: CGFloat = 900

    @ObservationIgnored private let store: AISessionStore
    @ObservationIgnored private let appSettings: AppSettings
    @ObservationIgnored private let usageQuota: UsageQuotaService
    @ObservationIgnored private let aiMonitor: AICLIMonitorService
    @ObservationIgnored private let chatBubble: ChatBubbleController
    @ObservationIgnored private let hover = EdgeBarHoverIntent()
    @ObservationIgnored private let rowSwitch = EdgeBarRowSwitch()
    @ObservationIgnored private var window: EdgeBarWindow?
    @ObservationIgnored private var hosting: EdgeBarHostingView?
    @ObservationIgnored private var buttonRects: [CardButton: CGRect] = [:]
    @ObservationIgnored private var beatTimer: Timer?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var usagePrimed = false
    /// Every readable line, before fitting to the window.
    @ObservationIgnored private var rawUsageLines: [EdgeBarUsageLine] = []

    init(
        store: AISessionStore,
        appSettings: AppSettings,
        usageQuota: UsageQuotaService,
        aiMonitor: AICLIMonitorService,
        chatBubble: ChatBubbleController
    ) {
        self.store = store
        self.appSettings = appSettings
        self.usageQuota = usageQuota
        self.aiMonitor = aiMonitor
        self.chatBubble = chatBubble
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        hover.onChange = { [weak self] open in
            open ? self?.openBar() : self?.closeBar()
        }
        rowSwitch.onSelect = { [weak self] id in self?.select(id) }
        observe()
        // Display reconfigurations, wake and unlock can leave the window
        // parked at a stale origin or without a rendered surface: re-dock.
        // Async (the Task hop) — never touch windows inside the screen
        // notification's dispatch (AGENTS.md, screen-reconfig crash family).
        for name in [NSApplication.didChangeScreenParametersNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyDock() }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            NSWorkspace.shared.notificationCenter
                .addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.applyDock() }
                }
        }
    }

    // MARK: - Store

    private func observe() {
        withObservationTracking {
            _ = store.sortedSessions.map { "\($0.id):\($0.phase):\($0.lastEventTime)" }
            _ = appSettings.aiStatusFabEnabled
            _ = usageQuota.quotas
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
            }
        }
        refresh()
    }

    private func refresh() {
        guard appSettings.aiStatusFabEnabled else {
            hover.closeNow()
            window?.orderOut(nil)
            updateBeat()
            return
        }
        if window == nil {
            makeWindow()
        } else if window?.isVisible == false {
            applyDock()
        }
        let next = EdgeBarModel.content(of: store.sortedSessions)
        if next != content {
            content = next
        }
        // One read at launch so the first opening isn't empty — only when the
        // bar is on (guarded above) and never in a test host / UI-test run
        // (real APIs, credential files, possibly the Keychain).
        if !usagePrimed, Self.mayReadUsage {
            usagePrimed = true
            Task { await usageQuota.refresh(force: false) }
        }
        rawUsageLines = EdgeBarUsage.lines(from: usageQuota.quotas, previous: rawUsageLines)
        fitUsage()
        let width = EdgeBarModel.openWidth(of: next, usage: usageLines)
        if width != openWidth {
            openWidth = width
        }
        setIfChanged(\.scrollOffset, min(scrollOffset, EdgeBarMetrics.maxScrollOffset(rows: next.rows.count)))
        if let selectedRow, !next.rows.contains(where: { $0.id == selectedRow }) {
            deselect()
        } else if let selectedRow, let slot = next.rows.firstIndex(where: { $0.id == selectedRow }) {
            setIfChanged(\.cardSlot, slot)
        }
        updateBodyRect()
        updateBeat()
    }

    func session(_ id: String) -> AISessionState? {
        store.get(id)
    }

    // MARK: - Window

    private func makeWindow() {
        let hosting = EdgeBarHostingView(rootView: AnyView(
            EdgeBarView()
                .environment(self)
        ))
        hosting.onPointer = { [weak self] in self?.pointer($0) }
        hosting.onClick = { [weak self] in self?.click(at: $0) ?? false }
        hosting.onScroll = { [weak self] in self?.scroll(at: $0, deltaY: $1, precise: $2) ?? false }
        let window = EdgeBarWindow(frame: .zero, hosting: hosting)
        self.hosting = hosting
        self.window = window
        applyDock()
    }

    /// The bar pins to the BUILT-IN screen's left edge (external displays
    /// here flap, and a bar on a dropped display is simply gone).
    private func dockScreen() -> NSScreen? {
        NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) ?? NSScreen.screens.first
    }

    /// Frame, bar position and order: the envelope spans the visible height,
    /// the bar's head sits where a full bar centred on the screen would start.
    func applyDock() {
        guard appSettings.aiStatusFabEnabled, let window, let screen = dockScreen() else { return }
        let visible = screen.visibleFrame
        let headScreenY = screen.frame.midY + EdgeBarMetrics.anchorLength / 2
        let top = min(max(EdgeBarMetrics.gutter, visible.maxY - headScreenY), visible.height / 3)
        if top != barTop {
            barTop = top
        }
        if visible.height != canvasHeight {
            canvasHeight = visible.height
        }
        window.setFrame(NSRect(
            x: visible.minX,
            y: visible.minY,
            width: EdgeBarMetrics.canvasWidth,
            height: visible.height
        ), display: true)
        window.orderFrontRegardless()
        // The room under the bar may have changed: refit the usage block.
        fitUsage()
        setIfChanged(\.openWidth, EdgeBarModel.openWidth(of: content, usage: usageLines))
        updateBodyRect()
    }

    /// The body's hover/hit rect: the TARGET size (open or closed), not the
    /// animating one — so the strip an opening reveals already counts as
    /// inside, and a closing body stops taking clicks at once.
    private func updateBodyRect() {
        let width = isOpen ? openWidth : EdgeBarMetrics.barWidth
        hosting?.bodyRect = CGRect(x: 0, y: barTop, width: width, height: bodyLength)
    }

    /// Usage cut to the room under the bar's top in the window.
    private func fitUsage() {
        let room = canvasHeight - barTop - EdgeBarMetrics.gutter
        let fitted = EdgeBarUsage.fitting(rawUsageLines, rows: content.rows.count, maxLength: room)
        setIfChanged(\.usageLines, fitted)
    }

    private static var mayReadUsage: Bool {
        !UITestMode.isActive && !UITestMode.isTestHost
    }

    var bodyLength: CGFloat {
        isOpen && (!content.rows.isEmpty || !usageLines.isEmpty)
            ? EdgeBarMetrics.openLength(rows: content.rows.count, usageLines: usageLines.count)
            : EdgeBarMetrics.closedLength(slots: content.closedSlots)
    }

    // MARK: - Pointer

    private func pointer(_ pointer: EdgeBarHostingView.Pointer) {
        switch pointer {
        case .entered:
            hover.pointerEntered()
        case .exited:
            rowSwitch.cancel()
            setIfChanged(\.hoveredRow, nil)
            setIfChanged(\.hoveredButton, nil)
            setIfChanged(\.isOverHead, false)
            hover.pointerExited()
        case let .moved(point):
            let bar = barPoint(point)
            setIfChanged(\.isOverHead, EdgeBarMetrics.isOverHead(x: bar.x, y: bar.y))
            // A move is only reported inside the bar, so it also says "still
            // here" — cancelling a close left pending by a missed enter.
            hover.pointerEntered()
            let row = row(at: bar)
            setIfChanged(\.hoveredRow, row)
            rowSwitch.hover(row, selected: selectedRow)
            setIfChanged(\.hoveredButton, button(at: point))
        }
    }

    /// Canvas point → bar coordinates (x from the edge, y from the bar's top).
    private func barPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y - barTop)
    }

    private func row(at bar: CGPoint) -> String? {
        guard isOpen,
              let slot = EdgeBarMetrics.slot(
                  x: bar.x, y: bar.y, width: openWidth,
                  rows: content.rows.count, offset: scrollOffset
              )
        else { return nil }
        return content.rows[slot].id
    }

    private func button(at point: CGPoint) -> CardButton? {
        guard selectedRow != nil else { return nil }
        return buttonRects.first(where: { $0.value.contains(point) })?.key
    }

    // MARK: - Open / close / select

    private func openBar() {
        // The one moment the usage reading is about to be seen: refresh it
        // (the service throttles to once a minute) — no timer on the bar.
        // After the opening's curve: credential reads run on the main actor
        // and must not land on the animation's first frames.
        if Self.mayReadUsage {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(EdgeBarMotion.usageRefreshDelay))
                guard let self, isOpen else { return }
                await usageQuota.refresh(force: false)
            }
        }
        isOpen = true
        updateBodyRect()
        updateBeat()
        // The still cursor's row (the bar opened under it).
        if let window, let hosting {
            let point = hosting.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            pointer(.moved(point))
        }
    }

    private func closeBar() {
        deselect()
        hoveredRow = nil
        isOpen = false
        scrollOffset = 0
        updateBodyRect()
        updateBeat()
    }

    private func select(_ id: String) {
        guard isOpen, let slot = content.rows.firstIndex(where: { $0.id == id }) else { return }
        cardSlot = slot
        selectedRow = id
    }

    private func deselect() {
        rowSwitch.cancel()
        buttonRects = [:]
        hoveredButton = nil
        pressedButton = nil
        selectedRow = nil
        hosting?.cardRect = nil
    }

    // MARK: - Card geometry (reported by the view)

    /// The card's drawn rect; with the gap toward the body it is the second
    /// hover area, so the way from a row to the card never leaves the bar.
    func cardFrameChanged(_ rect: CGRect?) {
        guard selectedRow != nil, let rect else {
            hosting?.cardRect = nil
            return
        }
        // Whole points: through its transition the frame moves by fractions
        // every frame, and each change rebuilds the tracking areas.
        var hoverRect = rect.integral
        hoverRect.origin.x -= EdgeBarMetrics.cardGap
        hoverRect.size.width += EdgeBarMetrics.cardGap
        hosting?.cardRect = hoverRect
    }

    func buttonFrameChanged(_ button: CardButton, _ rect: CGRect?) {
        buttonRects[button] = rect
    }

    // MARK: - Clicks and scroll

    /// The bar takes the card's buttons and the head (the chat bubble).
    /// Rows take none: the card comes by hover.
    private func click(at point: CGPoint) -> Bool {
        if let button = button(at: point), let id = selectedRow {
            press(button) { [weak self] in self?.perform(button, sessionId: id) }
            return true
        }
        let bar = barPoint(point)
        if EdgeBarMetrics.isOverHead(x: bar.x, y: bar.y) {
            hover.closeNow()
            chatBubble.toggle()
            return true
        }
        return false
    }

    /// Shows the press, then runs the action (which may close the card).
    private func press(_ button: CardButton, _ action: @escaping () -> Void) {
        pressedButton = button
        DispatchQueue.main.asyncAfter(deadline: .now() + EdgeBarMotion.pressFeedback) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pressedButton == button else { return }
                self.pressedButton = nil
                action()
            }
        }
    }

    private func perform(_ button: CardButton, sessionId: String) {
        switch button {
        case .allow:
            aiMonitor.respondToPermission(sessionId: sessionId, approved: true)
        case .deny:
            aiMonitor.respondToPermission(sessionId: sessionId, approved: false)
        case .jump:
            guard let session = store.get(sessionId) else { return }
            hover.closeNow()
            AppActivator.activate(
                pid: session.launchingAppPID,
                expectedBundleId: session.launchingAppBundleId,
                tabLink: session.tabLinkURL
            )
        }
    }

    private func scroll(at point: CGPoint, deltaY: CGFloat, precise: Bool) -> Bool {
        let bar = barPoint(point)
        guard isOpen,
              EdgeBarMetrics.isOverList(x: bar.x, y: bar.y, width: openWidth, rows: content.rows.count)
        else { return false }
        let maxOffset = EdgeBarMetrics.maxScrollOffset(rows: content.rows.count)
        let next = min(max(0, scrollOffset - (precise ? deltaY : deltaY * 16)), maxOffset)
        guard next != scrollOffset else { return true }
        scrollOffset = next
        if let selectedRow, let slot = content.rows.firstIndex(where: { $0.id == selectedRow }),
           !EdgeBarMetrics.isRowVisible(slot, rows: content.rows.count, offset: scrollOffset) {
            deselect()
        }
        pointer(.moved(point))
        return true
    }

    // MARK: - Beat

    /// The beat ticks only while a drawn ring is waiting for approval —
    /// otherwise the bar produces no frames at all.
    private func updateBeat() {
        let drawn = isOpen ? content.rows : content.closedRows
        let needed = appSettings.aiStatusFabEnabled && drawn.contains { $0.phase.isWaitingForApproval }
        if needed, beatTimer == nil {
            let timer = Timer(timeInterval: EdgeBarMotion.beatInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.beat &+= 1 }
            }
            timer.tolerance = EdgeBarMotion.beatInterval * 0.1
            RunLoop.main.add(timer, forMode: .common)
            beatTimer = timer
        } else if !needed, let timer = beatTimer {
            timer.invalidate()
            beatTimer = nil
        }
    }

    /// Pointer moves arrive at display rate: write only real changes.
    private func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<EdgeBarController, Value>,
        _ value: Value
    ) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }
}
