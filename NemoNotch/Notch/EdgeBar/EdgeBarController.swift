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
    /// Where the bar lives: docked to a screen's left or right edge, or a
    /// floating capsule anywhere.
    private(set) var placement = EdgeBarPlacement.load(from: .standard)
    /// Where the bar's top rests in the canvas, and the canvas height — set
    /// by the dock cycle and the drag so view and window never disagree.
    private(set) var restTop: CGFloat = 200
    private(set) var canvasHeight: CGFloat = 900

    var side: EdgeBarSide {
        placement.side
    }

    var isFloating: Bool {
        placement.mode == .floating
    }

    /// The anchored side's inset in the canvas: a docked bar sits on the
    /// window's edge; a capsule leaves the gutter for its shadow.
    var anchorInset: CGFloat {
        isFloating ? EdgeBarMetrics.gutter : 0
    }

    var canvasWidth: CGFloat {
        isFloating ? EdgeBarMetrics.floatingCanvasWidth : EdgeBarMetrics.canvasWidth
    }

    /// Where the bar's top is drawn: where it rests, except an opened capsule
    /// too low for its panel, which rises just enough to fit.
    var barTop: CGFloat {
        guard isFloating, isOpen else { return restTop }
        let lowest = canvasHeight - EdgeBarMetrics.gutter - bodyLength + EdgeBarMetrics.flare
        return max(EdgeBarMetrics.gutter - EdgeBarMetrics.flare, min(restTop, lowest))
    }

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
    @ObservationIgnored private var hostNames: [String: String?] = [:]
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
        setIfChanged(\.openWidth, measuredOpenWidth(next))
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

    /// The app the session runs in, named for the card's "Open in …".
    /// Cached per host: the card's body re-evaluates on every button hover,
    /// and a gone pid falls back to a synchronous LaunchServices lookup.
    func hostName(of session: AISessionState) -> String? {
        let key = "\(session.launchingAppPID.map(String.init) ?? "-")|\(session.launchingAppBundleId ?? "-")"
        if let cached = hostNames[key] {
            return cached
        }
        let name = AppActivator.appName(pid: session.launchingAppPID, bundleId: session.launchingAppBundleId)
        hostNames[key] = .some(name)
        return name
    }

    // MARK: - Window

    private func makeWindow() {
        let hosting = EdgeBarHostingView(rootView: AnyView(
            EdgeBarView()
                .environment(self)
        ))
        hosting.onPointer = { [weak self] in self?.pointer($0) }
        hosting.onMouseDown = { [weak self] point, _ in self?.mouseDown(at: point) ?? false }
        hosting.onScroll = { [weak self] in self?.scroll(at: $0, deltaY: $1, precise: $2) ?? false }
        let window = EdgeBarWindow(frame: .zero, hosting: hosting)
        self.hosting = hosting
        self.window = window
        applyDock()
    }

    /// The placement's screen while it is connected; else the built-in one
    /// (else the first) — a bar on a dropped display would simply be gone.
    private func dockScreen() -> NSScreen? {
        if let id = placement.screen, let screen = NSScreen.screens.first(where: { $0.displayUUID == id }) {
            return screen
        }
        return NSScreen.screens.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) ?? NSScreen.screens.first
    }

    /// Frame, bar position and order: the envelope spans the visible height,
    /// the bar's head sits where the user left it (a share of the height:
    /// survives a resolution change or another screen), by default where a
    /// full bar centred on the screen would start.
    func applyDock() {
        // A screen change landing mid-drag would yank the bar back.
        guard !isDragging, appSettings.aiStatusFabEnabled, let window, let screen = dockScreen() else { return }
        let visible = screen.visibleFrame
        setIfChanged(\.canvasHeight, visible.height)
        let top: CGFloat
        if let fraction = placement.top {
            top = fraction * visible.height
        } else {
            let headScreenY = screen.frame.midY + EdgeBarMetrics.anchorLength / 2
            top = min(max(EdgeBarMetrics.gutter, visible.maxY - headScreenY), visible.height / 3)
        }
        setIfChanged(\.restTop, isFloating ? clampedCapsuleTop(top) : clampedTop(top, canvasHeight: visible.height))
        window.setFrame(envelope(on: visible), display: true)
        window.orderFrontRegardless()
        // The room under the bar may have changed: refit the usage block.
        fitUsage()
        setIfChanged(\.openWidth, measuredOpenWidth(content))
        updateBodyRect()
    }

    /// The window: the visible height; across, from the docked edge, or
    /// around a capsule's anchored end.
    private func envelope(on visible: CGRect) -> NSRect {
        let x: CGFloat = switch (placement.mode, side) {
        case (.docked, .left):
            visible.minX
        case (.docked, .right):
            visible.maxX - canvasWidth
        case (.floating, .left):
            clampedAnchor(visible.minX + placement.anchor * visible.width, visible: visible) - anchorInset
        case (.floating, .right):
            clampedAnchor(visible.minX + placement.anchor * visible.width, visible: visible) + anchorInset - canvasWidth
        }
        return NSRect(x: x, y: visible.minY, width: canvasWidth, height: visible.height)
    }

    /// A capsule's anchored end, kept where the whole capsule (at its
    /// longest) stays on the screen.
    private func clampedAnchor(_ x: CGFloat, visible: CGRect) -> CGFloat {
        let longest = EdgeBarMetrics.capsuleLength(slots: EdgeBarMetrics.slotCount)
        return side == .left
            ? min(max(visible.minX, x), visible.maxX - longest)
            : min(max(visible.minX + longest, x), visible.maxX)
    }

    /// A capsule's rest top: the capsule whole inside the canvas.
    private func clampedCapsuleTop(_ top: CGFloat) -> CGFloat {
        let lowest = canvasHeight - EdgeBarMetrics.capsuleHeight - EdgeBarMetrics.capsuleTop
        return min(max(-EdgeBarMetrics.capsuleTop, top), lowest)
    }

    /// The open body's width, measured from the text. A capsule's panel is
    /// never narrower than the capsule: the cursor on the capsule's far end
    /// would be outside the panel it opened and fold it at once.
    private func measuredOpenWidth(_ content: EdgeBarModel.Content) -> CGFloat {
        let width = EdgeBarModel.openWidth(of: content, usage: usageLines)
        return isFloating ? max(width, EdgeBarMetrics.capsuleLength(slots: content.closedSlots)) : width
    }

    /// The body's rect in the canvas at its TARGET size (open or closed),
    /// not the animating one — so the strip an opening reveals already
    /// counts as inside, and a closing body stops taking clicks at once.
    private var bodyRect: CGRect {
        let size: CGSize
        let top: CGFloat
        if !isFloating {
            size = CGSize(width: isOpen ? openWidth : EdgeBarMetrics.barWidth, height: bodyLength)
            top = barTop
        } else if isOpen {
            size = CGSize(width: openWidth, height: bodyLength - 2 * EdgeBarMetrics.flare)
            top = barTop + EdgeBarMetrics.flare
        } else {
            size = CGSize(
                width: EdgeBarMetrics.capsuleLength(slots: content.closedSlots),
                height: EdgeBarMetrics.capsuleHeight
            )
            top = restTop + EdgeBarMetrics.capsuleTop
        }
        let x = side == .left ? anchorInset : canvasWidth - anchorInset - size.width
        return CGRect(origin: CGPoint(x: x, y: top), size: size)
    }

    /// The hover/hit rect follows the body's target.
    private func updateBodyRect() {
        hosting?.bodyRect = bodyRect
    }

    /// Usage cut to the room the open body has: under a docked bar's top; a
    /// capsule's panel rises to fit, so the canvas height.
    private func fitUsage() {
        let room = isFloating
            ? canvasHeight - 2 * (EdgeBarMetrics.gutter - EdgeBarMetrics.flare)
            : canvasHeight - restTop - EdgeBarMetrics.gutter
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
        // Mid-drag the cursor rides the bar: no opening, no rows.
        if isDragging {
            return
        }
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

    /// Canvas point → bar coordinates (x from the anchored side, y from the
    /// bar's top).
    private func barPoint(_ point: CGPoint) -> CGPoint {
        let anchor = side == .left ? anchorInset : canvasWidth - anchorInset
        return CGPoint(x: (point.x - anchor) * side.sign, y: point.y - barTop)
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
        if side == .left {
            hoverRect.origin.x -= EdgeBarMetrics.cardGap
        }
        hoverRect.size.width += EdgeBarMetrics.cardGap
        hosting?.cardRect = hoverRect
    }

    func buttonFrameChanged(_ button: CardButton, _ rect: CGRect?) {
        buttonRects[button] = rect
    }

    // MARK: - Drag (slide along the edge, or carry the capsule anywhere)

    /// Past this many points of travel a press on the body is a drag.
    static let dragThreshold: CGFloat = 4
    /// Pulled this far off its edge, a docked bar comes away as a capsule.
    static let tearOff: CGFloat = 48

    @ObservationIgnored private var isDragging = false

    /// Kept where the OPEN body still fits below it — the longest list
    /// (7.5 rows and the summary); the usage block fits itself to what room
    /// is left (`fitUsage`), and the card clamps itself to the canvas.
    private func clampedTop(_ top: CGFloat, canvasHeight: CGFloat) -> CGFloat {
        let longest = EdgeBarMetrics.openLength(rows: Int(EdgeBarMetrics.visibleRows.rounded(.up)))
        let lowest = canvasHeight - longest - EdgeBarMetrics.gutter
        return min(max(EdgeBarMetrics.gutter, top), max(EdgeBarMetrics.gutter, lowest))
    }

    /// A press on the body (not a card button) may become a drag. A docked
    /// bar slides along its edge until pulled off it; a capsule — or a bar
    /// pulled off — follows the cursor anywhere, across screens, and on
    /// release docks to an edge it is near or floats where it is. A press
    /// that never travels is a click. The tracking loop runs the
    /// event-tracking runloop, so the bar redraws while it follows the cursor.
    private func mouseDown(at point: CGPoint) -> Bool {
        guard let window, let hosting, button(at: point) == nil, hosting.bodyRect.contains(point)
        else { return click(at: point) }

        let start = NSEvent.mouseLocation
        let startTop = restTop
        // A closed capsule is carried by the point pressed on it (from its
        // anchored end's top corner); a docked bar or an opened panel by
        // the head, the capsule's anchored end.
        let body = hosting.bodyRect
        let grab = isFloating && !isOpen
            ? CGPoint(x: (point.x - (side == .left ? body.minX : body.maxX)) * side.sign, y: point.y - body.minY)
            : CGPoint(x: EdgeBarMetrics.barWidth / 2, y: EdgeBarMetrics.capsuleHeight / 2)
        var dragging = false
        var carrying = isFloating
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                break
            }
            let cursor = NSEvent.mouseLocation
            // Screen y grows upward; the bar's top is measured downward.
            let dx = cursor.x - start.x
            let dy = start.y - cursor.y
            if !dragging {
                guard max(abs(dx), abs(dy)) > Self.dragThreshold else { continue }
                dragging = true
                isDragging = true
                hover.closeNow()
            }
            if !carrying, abs(dx) > Self.tearOff {
                carrying = true
            }
            if carrying {
                carry(to: cursor, grab: grab)
            } else {
                setIfChanged(\.restTop, clampedTop(startTop + dy, canvasHeight: canvasHeight))
                updateBodyRect()
            }
        }
        // The loop consumed the mouse-up: whatever click() says, the press
        // is ours (handing SwiftUI a down with no up would leave it stuck).
        guard dragging else {
            _ = click(at: point)
            return true
        }
        isDragging = false
        if carrying {
            settle()
        } else {
            placement.top = restTop / canvasHeight
        }
        placement.save(to: .standard)
        applyDock()
        LogService.info(
            "Edge bar placed: \(placement.mode.rawValue) \(placement.side.rawValue), top \(Int(restTop)) / \(Int(canvasHeight))",
            category: "EdgeBar"
        )
        return true
    }

    /// The capsule under the cursor, held by `grab`, on whichever screen the
    /// cursor is over. Its anchored end follows the room: the left end while
    /// the opened list and card fit to its right, else the right end.
    private func carry(to cursor: CGPoint, grab: CGPoint) {
        guard let window, let screen = NSScreen.screen(containing: cursor) ?? dockScreen() else { return }
        let visible = screen.visibleFrame
        let side = EdgeBarPlacement.floatingSide(
            leftEnd: cursor.x - grab.x,
            visible: visible,
            reach: EdgeBarMetrics.reach,
            current: isFloating ? side : .left
        )
        let anchor = cursor.x - side.sign * grab.x
        setIfChanged(\.placement, EdgeBarPlacement(
            mode: .floating,
            side: side,
            screen: screen.displayUUID,
            top: placement.top,
            anchor: (anchor - visible.minX) / max(1, visible.width)
        ))
        setIfChanged(\.canvasHeight, visible.height)
        let capsuleTop = visible.maxY - cursor.y - grab.y
        setIfChanged(\.restTop, clampedCapsuleTop(capsuleTop - EdgeBarMetrics.capsuleTop))
        placement.top = restTop / visible.height
        window.setFrame(envelope(on: visible), display: true)
        setIfChanged(\.openWidth, measuredOpenWidth(content))
        updateBodyRect()
    }

    /// Released: docked to an edge it was released near, else floating
    /// where it is.
    private func settle() {
        guard let window, let screen = dockScreen() else { return }
        let visible = screen.visibleFrame
        let body = bodyRect
        // Canvas (top-down) → screen (bottom-up).
        let capsule = CGRect(
            x: window.frame.minX + body.minX,
            y: visible.maxY - body.maxY,
            width: body.width,
            height: body.height
        )
        setIfChanged(\.placement, EdgeBarPlacement.dropped(
            capsule: capsule,
            visible: visible,
            side: side,
            top: restTop / canvasHeight,
            screen: screen.displayUUID
        ))
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
