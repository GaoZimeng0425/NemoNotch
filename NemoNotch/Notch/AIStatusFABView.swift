import AppKit
import SwiftUI

/// The floating AI-status button. A SINGLE root view whose body is a `ZStack`
/// of three always-present layers (background shape, capsule content, panel
/// content) — the capsule↔panel transition is driven entirely by SwiftUI
/// value-bound `.animation(_:value: isExpanded)`, mirroring `NotchView`. The
/// hosting window is a fixed canvas that never resizes on toggle, so there is
/// no flicker from re-hosting or `setFrame(animate:)`.
struct AIStatusFABView: View {
    @Environment(AISessionStore.self) var store
    @Environment(ChatBubbleController.self) var chatBubble
    @Environment(\.aiStatusController) var controller

    private var isExpanded: Bool {
        controller?.isExpanded ?? false
    }

    /// Measured width of the collapsed pill's content (see `capsuleWidth`).
    /// The seed only has to be sane for the single layout pass before the first
    /// measurement lands.
    @State private var measuredCapsuleWidth: CGFloat = 92

    /// Session chip currently under the cursor; drives the hover preview card.
    @State private var hoveredSessionId: String?
    /// Grace timer keeping the card alive while the pointer crosses the dead
    /// gap between the chip and the card below it.
    @State private var hoverGraceTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Layer 0 — the morphing background shape. Its frame + corner radius
            // are functions of `isExpanded`; the value-bound animation tweens
            // them (capsule pill ↔ panel 14pt rounded rect). This is the
            // "stretch" carrier, analogous to `NotchBackgroundView`.
            backgroundShape
                .animation(fabStateAnimation, value: isExpanded)
                .animation(capsuleWidthAnimation, value: capsuleWidth)
                .zIndex(0)

            // Layers 1+2 — content, clipped by the SAME morphing geometry as
            // the background. Each layer's own opacity/scale crossfade animates
            // different properties (and ranges) than the background's frame
            // tween, so without a shared clip they can never align
            // frame-by-frame — mid-morph the panel content visibly stuck out
            // past the still-growing shape.
            ZStack(alignment: .topTrailing) {
                // Layer 1 — capsule content (shown when collapsed). Always
                // present; faded/scaled out when expanding so it reads as
                // "growing into" the panel, like `NotchView`'s CompactBadgesView.
                capsuleContent
                    .opacity(isExpanded ? 0 : 1)
                    .scaleEffect(isExpanded ? 0.8 : 1, anchor: .topTrailing)
                    .allowsHitTesting(!isExpanded)
                    .animation(fabStateAnimation, value: isExpanded)

                // Layer 2 — panel content (shown when expanded). Always present;
                // faded/scaled in on expand, like `NotchView`'s contentPanel.
                panelContent
                    .opacity(isExpanded ? 1 : 0)
                    .scaleEffect(isExpanded ? 1 : 0.85, anchor: .topTrailing)
                    .allowsHitTesting(isExpanded)
                    .animation(fabStateAnimation, value: isExpanded)
            }
            .mask(alignment: .topTrailing) { morphShape }
            .zIndex(1)

            // Layer 3 — hover preview card. Deliberately OUTSIDE the mask: the
            // content ZStack above is clipped to the morphing shape, which is
            // the 32pt pill while collapsed and would shear the card away. The
            // fixed canvas has transparent, click-through room below the pill
            // (PassThroughView), so the card needs no window changes.
            hoverCard
                .zIndex(2)
        }
        // Anchor the visible shape to the top-right of the fixed canvas; the
        // transparent remainder (bottom-left) click-throughs via PassThroughView.
        .frame(
            width: NotchConstants.aiStatusFabPanelWidth + NotchConstants.aiStatusFabShadowPad * 2,
            height: NotchConstants.aiStatusFabPanelHeight + NotchConstants.aiStatusFabShadowPad * 2,
            alignment: .topTrailing
        )
    }

    // MARK: - Spring animation (matches NotchView's notchStateAnimation)

    private var fabStateAnimation: Animation {
        if isExpanded {
            return .spring(duration: NotchConstants.aiStatusFabOpenSpringDuration, bounce: 0.1)
        }
        return .spring(duration: NotchConstants.aiStatusFabCloseSpringDuration)
    }

    /// Width tween for the collapsed pill when the set of status groups changes.
    private var capsuleWidthAnimation: Animation {
        .spring(duration: NotchConstants.aiStatusFabCloseSpringDuration)
    }

    // MARK: - Shared morph geometry (background shape + content mask)

    /// One source of truth for the pill↔panel footprint so the background fill
    /// and the content clip can never disagree — the clip edge tracks the
    /// animated shape exactly, every frame of the morph.
    private var morphWidth: CGFloat {
        isExpanded ? NotchConstants.aiStatusFabPanelWidth : capsuleWidth
    }

    private var morphHeight: CGFloat {
        isExpanded ? NotchConstants.aiStatusFabPanelHeight : NotchConstants.aiStatusFabCapsuleHeight
    }

    private var morphCornerRadius: CGFloat {
        // Collapsed → height/2 yields a pill; expanded → 14pt.
        isExpanded ? NotchConstants.aiStatusFabCornerRadius : NotchConstants.aiStatusFabCapsuleHeight / 2
    }

    private var morphShape: some View {
        RoundedRectangle(cornerRadius: morphCornerRadius, style: .continuous)
            .frame(width: morphWidth, height: morphHeight)
            .animation(fabStateAnimation, value: isExpanded)
            // The collapsed pill grows/shrinks as status groups appear and
            // disappear; without this the width would snap between frames.
            .animation(capsuleWidthAnimation, value: capsuleWidth)
    }

    // MARK: - Layer 0: background shape

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: morphCornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [NotchTheme.panelRaised, NotchTheme.panelBase],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(width: morphWidth, height: morphHeight)
            .overlay(
                RoundedRectangle(cornerRadius: morphCornerRadius, style: .continuous)
                    .stroke(NotchTheme.stroke, lineWidth: 0.6)
            )
            .shadow(
                color: .black.opacity(NotchConstants.openedShadowOpacity),
                radius: NotchConstants.openedShadowRadius
            )
    }

    /// The collapsed pill's width, **measured from the real laid-out content**
    /// rather than estimated. It has to be a number because the background
    /// shape and the content mask both take an explicit `.frame(width:)`, but
    /// the number must not be a guess: the chips are dot + count text, and a
    /// guess that came up short silently squeezed the count `Text` to zero
    /// width (the dots have rigid frames, so the text was the only thing that
    /// could absorb the shortfall). Same pattern as `NotchView.closedContentSize`.
    private var capsuleWidth: CGFloat {
        measuredCapsuleWidth
    }

    private var capsuleHPadding: CGFloat {
        12
    }

    private var capsuleChipSpacing: CGFloat {
        11
    }

    private var capsuleDotSize: CGFloat {
        10
    }

    private var capsuleChipSize: CGFloat {
        20
    }

    private var mascotSize: CGFloat {
        16
    }

    // MARK: - Layer 1: capsule content

    /// Aggregate capsule state — the most attention-needing phase across all
    /// sessions (approval > running > waiting-input). Drives the head dot and
    /// the expanded header; the per-session strip below is `sessionStrip`.
    private var capsuleState: FABCapsuleState {
        FABCapsuleState.of(store.sortedSessions)
    }

    /// Per-session chips on the strip (evlat-style, one ring per session).
    private var sessionStrip: FABSessionStrip {
        FABSessionStrip.of(store.sortedSessions, cap: NotchConstants.aiStatusFabChipCap)
    }

    /// Sessions the expanded panel lists: everything still mid-conversation
    /// (running or parked at a prompt / permission choice).
    private var engagedSessions: [AISessionState] {
        store.sortedSessions.filter(\.phase.isEngaged)
    }

    private var capsuleContent: some View {
        HStack(spacing: capsuleChipSpacing) {
            capsuleHead
            sessionChips
        }
        .padding(.horizontal, capsuleHPadding)
        .frame(height: NotchConstants.aiStatusFabCapsuleHeight)
        // Take the ideal width instead of whatever the 420pt-wide canvas offers:
        // the pill hugs its chips, and nothing inside can be compressed.
        .fixedSize(horizontal: true, vertical: false)
        // Feed the measured width to the morphing shape + mask. Assigned
        // WITHOUT `withAnimation` on purpose (mirroring NotchView): this fires
        // on every layout pass, and the single spring lives on the shape.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard width > 0 else { return }
            measuredCapsuleWidth = width
        }
    }

    /// The pill's head — the mascot slot: the app icon, the ONLY drag surface
    /// and the tap-to-expand anchor (the drag/click handle moved here now that
    /// each per-session chip handles its own taps; a capsule-wide handle would
    /// swallow them). It deliberately shows NO aggregate state: the chips are
    /// attention-ordered, so the first ring already is the worst state and a
    /// winning-state dot in front was pure duplication. Everything quiet keeps
    /// the hollow-green "done" look during the fade-out window, where it is
    /// the strip's only content.
    private var capsuleHead: some View {
        HStack(spacing: 6) {
            if capsuleState == .done {
                statusCircle(statusColor(.done), size: capsuleDotSize, hollow: true)
                capsuleLabel("done")
            } else {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: mascotSize, height: mascotSize)
                    .clipShape(RoundedRectangle(cornerRadius: mascotSize * 0.28, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: mascotSize * 0.28, style: .continuous)
                            .stroke(NotchTheme.stroke, lineWidth: 0.6)
                    )
            }
        }
        .frame(minWidth: 30)
        .contentShape(Rectangle())
        // The drag/click handle sits in `.overlay` (above the head content),
        // NOT `.background`: SwiftUI's hosting view dispatches AppKit mouseDown
        // to the topmost hit view first, so an overlay NSView reliably receives
        // mouseDown, while SwiftUI content above a background NSView would
        // swallow the event. A SwiftUI tap gesture is NOT paired with it — the
        // handle's own mouseDown loop decides drag-vs-click.
        .overlay(
            DragHandleView(
                onDrag: { controller?.beginWindowDrag(with: $0) },
                onTap: { controller?.toggleExpanded() }
            )
        )
    }

    /// One ring per engaged session (attention order, capped), then a "+N"
    /// overflow chip for the rest.
    @ViewBuilder
    private var sessionChips: some View {
        let strip = sessionStrip
        ForEach(strip.chips) { chip in
            sessionChip(chip)
        }
        if strip.overflow > 0 {
            Text("+\(strip.overflow)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NotchTheme.textSecondary)
                .help("\(strip.overflow) more sessions")
        }
    }

    /// One session indicator: the CLI source icon inside a ring colored by the
    /// session's phase — attention states glow harder. Click jumps to the host
    /// terminal; without a known host it expands the panel onto this session
    /// instead.
    ///
    /// Deliberately NO pulse on the ring: the ring's `repeatForever` animation
    /// renders interpolated frames against the chip's layout origin, and chips
    /// REORDER whenever phases flip (attention sort) — the stale-origin frames
    /// showed up as ghost rings sliding between slots (captured on screen:
    /// five rings for four chips). The head dot keeps its pulse; it is always
    /// the first element, so its origin never changes.
    private func sessionChip(_ chip: FABSessionChip) -> some View {
        let color = statusColor(chip.phase)
        return ZStack {
            Circle()
                .stroke(color, lineWidth: 2)
            sourceIcon(chip.source, size: 11)
        }
        .frame(width: capsuleChipSize, height: capsuleChipSize)
        .shadow(color: color.opacity(chip.phase.needsAttention ? 0.65 : 0.35), radius: capsuleChipSize / 3)
        // Tap + hover live in an AppKit overlay, NOT SwiftUI gestures:
        // SwiftUI discrete taps never fire in this non-activating panel
        // (NSHostingView rejects the first mouse and the panel is never
        // first-responder through the SwiftUI path), while NSView
        // mouseDown works — the head's drag handle always did. Hover is
        // handled by the same view so both interactions share one event
        // path.
        .overlay(
            ChipInteractView(
                onTap: { chipTapped(chip) },
                onHover: { setHovered(chip.id, hovering: $0) }
            )
        )
    }

    /// Tapping a chip opens the panel onto that session. Expand is the
    /// capsule's primary action and must not depend on hitting the small
    /// head: the first evlat-faithful revision made every chip a
    /// jump-to-terminal shortcut instead, which shrank the panel affordance
    /// to a ~30pt target that MOVES as chips come and go — users could no
    /// longer open the panel at all (reported, reverted same day).
    /// Jump-to-terminal lives in the hover card as an explicit button.
    private func chipTapped(_ chip: FABSessionChip) {
        LogService.debug("chipTapped expand", category: "FABDebug")
        selectedSessionId = chip.id
        // Chips are only hit-testable while collapsed, so the public
        // toggle lands on expand — the private expand() isn't reachable.
        controller?.toggleExpanded()
    }

    /// Keep the incoming hover unless a newer chip already took over — a
    /// leave from the previous chip can arrive after the enter on the next.
    /// Leaving the chip does NOT clear immediately: the pointer has to cross
    /// a dead gap to reach the card below, so the clear is deferred ~300ms
    /// and cancelled when the card's own hover asserts.
    private func setHovered(_ id: String, hovering: Bool) {
        withAnimation(.easeOut(duration: 0.15)) {
            if hovering {
                hoverGraceTask?.cancel()
                hoverGraceTask = nil
                hoveredSessionId = id
            } else if hoveredSessionId == id {
                hoverGraceTask?.cancel()
                hoverGraceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        if hoveredSessionId == id {
                            hoveredSessionId = nil
                        }
                    }
                }
            }
        }
    }

    /// Evlat-style hover peek: what this session is and where a click goes.
    /// Mounted only while a chip is hovered and the panel is collapsed.
    ///
    /// Positioned by LAYOUT (a full-canvas container + top padding), never by
    /// `.offset`: offset moves rendering only, so the card's hit-testing area
    /// stayed glued to the top-trailing corner — invisibly covering the
    /// rightmost chips. Every tap on a chip then landed on the card (no
    /// gesture → swallowed), moving onto the visible card left its hit area
    /// (card vanished), and the card's buttons were unclickable. Layout
    /// placement puts hit area and pixels in the same place.
    private var hoverCard: some View {
        ZStack(alignment: .topTrailing) {
            if !isExpanded,
               let chip = sessionStrip.chips.first(where: { $0.id == hoveredSessionId }),
               let session = store.get(chip.id) {
                hoverCardContent(chip, session)
                    .padding(.top, NotchConstants.aiStatusFabCapsuleHeight + 10)
                    .transition(.opacity)
            }
        }
        .frame(
            width: NotchConstants.aiStatusFabPanelWidth + NotchConstants.aiStatusFabShadowPad * 2,
            height: NotchConstants.aiStatusFabPanelHeight + NotchConstants.aiStatusFabShadowPad * 2,
            alignment: .topTrailing
        )
    }

    private func hoverCardContent(_ chip: FABSessionChip, _ session: AISessionState) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                sourceBadge(session.source)
                Text(session.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(chip.phase))
                    .frame(width: 7, height: 7)
                Text(phaseLabel(chip.phase))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchTheme.textSecondary)
                if let tool = session.currentTool, !tool.isEmpty {
                    toolBadge(tool, tint: sourceTint(session.source))
                }
            }
            if chip.phase.isWaitingForApproval || chip.hasHost {
                HStack(spacing: 6) {
                    if chip.phase.isWaitingForApproval {
                        // Answer from the capsule — the whole point of the
                        // amber state; no need to open the notch or the
                        // terminal.
                        answerButton(chip, title: "Deny", approved: false)
                        answerButton(chip, title: "Allow", approved: true)
                    }
                    if chip.hasHost {
                        jumpButton(chip)
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 210, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(NotchTheme.panelBase.opacity(0.97))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(NotchTheme.stroke, lineWidth: 0.6)
        )
        .shadow(
            color: .black.opacity(NotchConstants.openedShadowOpacity),
            radius: NotchConstants.openedShadowRadius
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Hovering the card itself re-asserts the chip's hover — this is
        // what keeps the card (and its answer buttons) alive while the
        // pointer travels off the chip.
        .onHover { setHovered(chip.id, hovering: $0) }
    }

    /// Explicit jump-to-terminal button in the hover card. The jump used to
    /// be the chip tap itself; it moved here when chip taps became
    /// expand-and-select (see chipTapped).
    private func jumpButton(_ chip: FABSessionChip) -> some View {
        Button {
            guard let session = store.get(chip.id) else { return }
            AppActivator.activate(
                pid: session.launchingAppPID,
                expectedBundleId: session.launchingAppBundleId,
                tabLink: session.tabLinkURL
            )
        } label: {
            Text(String(localized: "fab.jump"))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(NotchTheme.accentText)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(NotchTheme.accentText.opacity(0.14))
                .clipShape(Capsule(style: .continuous))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Tiny capsule button answering a permission from the hover card.
    private func answerButton(_ chip: FABSessionChip, title: String, approved: Bool) -> some View {
        let tint: Color = approved
            ? Color(red: 0.30, green: 0.85, blue: 0.45)
            : Color(red: 1.0, green: 0.34, blue: 0.28)
        return Button {
            controller?.respondToPermission(sessionId: chip.id, approved: approved)
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(tint.opacity(0.16))
                .clipShape(Capsule(style: .continuous))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func phaseLabel(_ phase: SessionPhase) -> String {
        switch phase {
        case .processing: "running"
        case .compacting: "compacting"
        case .waitingForApproval: "waiting for approval"
        case .waitingForInput: "waiting for input"
        case .idle, .ended: "idle"
        }
    }

    /// Shared dot renderer for the capsule and the expanded header: solid +
    /// glowing normally, stroke-only for the `done` state.
    @ViewBuilder
    private func statusCircle(
        _ color: Color,
        size: CGFloat,
        hollow: Bool,
        pulsing: Bool = false
    ) -> some View {
        if hollow {
            Circle()
                .stroke(color, lineWidth: size * 0.15)
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.7), radius: size / 2)
                .modifier(PulseModifier(isActive: pulsing))
        }
    }

    private func capsuleLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(NotchTheme.textSecondary)
    }

    // MARK: - Layer 2: panel content (layout B: list + detail)

    @State private var selectedSessionId: String?

    private var selectedSession: AISessionState? {
        if let id = selectedSessionId, let s = store.get(id) {
            return s
        }
        return engagedSessions.first
    }

    private var panelContent: some View {
        VStack(spacing: 0) {
            header
            Divider().background(NotchTheme.stroke)
            HStack(spacing: 0) {
                sessionList
                    .frame(width: NotchConstants.aiStatusFabListColumnWidth)
                Divider().background(NotchTheme.stroke)
                detailPane
            }
            Divider().background(NotchTheme.stroke)
            quotaStrip
        }
        .frame(
            width: NotchConstants.aiStatusFabPanelWidth,
            height: NotchConstants.aiStatusFabPanelHeight
        )
        .clipShape(
            RoundedRectangle(cornerRadius: NotchConstants.aiStatusFabCornerRadius, style: .continuous)
        )
    }

    /// Usage/quota footer. Its height is reserved unconditionally so expanding
    /// never reflows the list above it, but the strip itself is mounted only
    /// while expanded: the panel layer stays in the view tree at `opacity(0)`
    /// when collapsed, and an always-mounted strip would keep `UsageQuotaService`
    /// active (and polling) for as long as the capsule is on screen.
    private var quotaStrip: some View {
        Group {
            if isExpanded {
                AIStatusQuotaStrip()
            }
        }
        .frame(height: NotchConstants.aiStatusFabQuotaStripHeight)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 8) {
            headerDot
            Text(headerStatusLabel)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NotchTheme.textPrimary)
            Text("· AI sessions")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            Spacer(minLength: 8)
            Button {
                chatBubble.show()
            } label: {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(NotchTheme.surface))
                    .overlay(Circle().stroke(NotchTheme.stroke, lineWidth: 0.6))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("chat_bubble.open")
            Button {
                controller?.collapse()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(NotchTheme.surface))
                    .overlay(Circle().stroke(NotchTheme.stroke, lineWidth: 0.6))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Collapse")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Expanded-state drag handle. `isMovableByWindowBackground` is false
        // (so list-row taps don't start a drag); dragging is moved here, to the
        // header, via performDrag. The collapse button sits above this
        // background and still receives its taps normally.
        .background(DragHandleView { controller?.beginWindowDrag(with: $0) })
    }

    /// Miniature of the capsule dot in the expanded header — same state color,
    /// hollow for `done`.
    @ViewBuilder
    private var headerDot: some View {
        let color = statusColor(capsuleState)
        if capsuleState == .done {
            Circle().stroke(color, lineWidth: 1.2).frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.6), radius: 4)
        }
    }

    private var headerStatusLabel: String {
        switch capsuleState {
        case let .running(count): "\(count) running"
        case let .waitingApproval(count): count == 1 ? "1 approval" : "\(count) approvals"
        case let .waitingInput(count): "\(count) awaiting input"
        case .done: "done"
        }
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(engagedSessions) { session in
                    let isSelected = session.id == selectedSession?.id
                    HStack(spacing: 7) {
                        statusDot(session.phase)
                        sourceBadge(session.source)
                        Text(session.displayTitle)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? NotchTheme.textPrimary : NotchTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(isSelected ? NotchTheme.accent.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedSessionId = session.id }
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let session = selectedSession {
            detailContent(session)
        } else {
            Text("No session")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailContent(_ session: AISessionState) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                sourceIcon(session.source, size: 16)
                Text(session.displayTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                // Jump to the terminal/IDE hosting this session. Hidden when
                // no host was resolved (opencode plugin events, tmux/ssh) —
                // a dead button would be worse than none.
                if session.launchingAppPID != nil {
                    Button {
                        AppActivator.activate(
                            pid: session.launchingAppPID,
                            expectedBundleId: session.launchingAppBundleId,
                            tabLink: session.tabLinkURL
                        )
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(NotchTheme.textSecondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(NotchTheme.surface))
                            .overlay(Circle().stroke(NotchTheme.stroke, lineWidth: 0.6))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in Terminal")
                }
            }
            if let tool = session.currentTool, !tool.isEmpty {
                toolBadge(tool, tint: sourceTint(session.source))
            }
            // Context progress
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: session.contextPercent)
                    .tint(NotchTheme.accent)
                HStack {
                    Text("ctx \(String(format: "%.0f%%", session.contextPercent * 100))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NotchTheme.textTertiary)
                    Spacer()
                    Text("\(session.contextTokenDisplay) / \(session.contextLimitDisplay)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NotchTheme.textTertiary)
                }
            }
            detailRow("Model", session.displayModel ?? "—")
            detailRow("Tokens", session.tokenDisplay)
            detailRow("Folder", session.projectFolder ?? "—")
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NotchTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func toolBadge(_ tool: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .bold))
            Text(tool)
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14))
        .clipShape(Capsule(style: .continuous))
    }

    // MARK: - Status colors (herdr traffic-light semantics)

    /// Yellow = running, red = needs a choice, green = awaiting input /
    /// finished. `done` shares the awaiting-input green but renders hollow.
    private func statusColor(_ state: FABCapsuleState) -> Color {
        switch state {
        case .running: Color(red: 0.98, green: 0.75, blue: 0.20) // yellow
        case .waitingApproval: Color(red: 1.0, green: 0.34, blue: 0.28) // red
        case .waitingInput, .done: Color(red: 0.30, green: 0.85, blue: 0.45) // green
        }
    }

    /// Per-session list dot — the same mapping, keyed by the finer-grained
    /// phase (distinguishes approval-red from input-green, which the derived
    /// `ClaudeStatus` collapses into one `.waiting`).
    private func statusColor(_ phase: SessionPhase) -> Color {
        switch phase {
        case .processing, .compacting: Color(red: 0.98, green: 0.75, blue: 0.20) // yellow — running
        case .waitingForApproval: Color(red: 1.0, green: 0.34, blue: 0.28) // red — needs a choice
        case .waitingForInput: Color(red: 0.30, green: 0.85, blue: 0.45) // green — awaiting input
        case .idle, .ended: NotchTheme.textTertiary // gray
        }
    }

    /// 7pt solid list-row dot (the hollow form is capsule-only).
    @ViewBuilder
    private func statusDot(_ phase: SessionPhase) -> some View {
        let color = statusColor(phase)
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.7), radius: 3)
    }

    // MARK: - Source badge / icon (reuses the public icon components)

    private func sourceBadge(_ source: AISource) -> some View {
        let tint = sourceTint(source)
        return sourceIcon(source, size: 14)
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
            .background(tint.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    @ViewBuilder
    private func sourceIcon(_ source: AISource, size: CGFloat) -> some View {
        let tint = sourceTint(source)
        switch source {
        case .claude:
            ClaudeCrabIcon(size: size, color: tint)
        case .gemini:
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(tint)
        case .opencode:
            OpencodeLogoIcon(size: size, color: tint)
        case .zcode:
            ZcodeLogoIcon(size: size, color: tint)
        }
    }

    private func sourceTint(_ source: AISource) -> Color {
        switch source {
        case .claude: NotchTheme.accentText
        case .gemini: Color(red: 0.42, green: 0.68, blue: 1.0)
        case .opencode: Color(red: 0.55, green: 0.78, blue: 0.55)
        case .zcode: Color(red: 0.11, green: 0.44, blue: 0.96)
        }
    }
}

// MARK: - Chip interaction (AppKit)

/// Transparent AppKit view owning a chip's tap and hover. `mouseDown`
/// tracks to `mouseUp` and fires `onTap` (chips don't drag — dragging is
/// the head's job); a tracking area drives `onHover` for the preview card.
/// Everything here rides the same NSView event path as `DragHandleView`,
/// which is the only event path that works in this non-activating panel.
private struct ChipInteractView: NSViewRepresentable {
    let onTap: () -> Void
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> InteractView {
        InteractView(onTap: onTap, onHover: onHover)
    }

    func updateNSView(_ view: InteractView, context: Context) {
        view.onTap = onTap
        view.onHover = onHover
    }

    final class InteractView: NSView {
        var onTap: () -> Void
        var onHover: (Bool) -> Void

        init(onTap: @escaping () -> Void, onHover: @escaping (Bool) -> Void) {
            self.onTap = onTap
            self.onHover = onHover
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError()
        }

        override var acceptsFirstResponder: Bool {
            false
        }

        override var isFlipped: Bool {
            true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.userInfo?["hover"] != nil {
                removeTrackingArea(area)
            }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,
                    .activeInKeyWindow,
                    .activeWhenFirstResponder,
                    .inVisibleRect,
                ],
                owner: self,
                userInfo: ["hover": "hover"]
            ))
        }

        override func mouseEntered(with event: NSEvent) {
            onHover(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHover(false)
        }

        override func mouseDown(with event: NSEvent) {
            LogService.debug("interact mouseDown", category: "FABDebug")
            guard event.buttonNumber == 0 else {
                super.mouseDown(with: event)
                return
            }
            // Tap: wait for mouseUp (anywhere — a tiny slide off the 20pt
            // chip still reads as the intended click).
            let up = window?.nextEvent(matching: [.leftMouseUp])
            LogService.debug("interact got up: \(up != nil)", category: "FABDebug")
            onTap()
        }
    }
}

// MARK: - Drag handle

/// Transparent AppKit view placed behind the capsule body and the expanded
/// panel's header. `mouseDown` runs a drag-vs-click tracking loop:
///   - if the mouse moves beyond the drag threshold → `onDrag` → window drag;
///   - if the mouse is released without moving → `onTap` (toggle expand/collapse).
///
/// This resolves the gesture conflict that arises when a SwiftUI `.onTapGesture`
/// and a drag `.background` both claim the same press: there is a single
/// AppKit entry point (`mouseDown`) that decides which gesture wins, so we do
/// NOT pair this with a SwiftUI tap gesture on the same view.
///
/// `acceptsFirstMouse` returns true so a click onto the FAB (a non-activating
/// panel) acts immediately without a preliminary focus click.
private struct DragHandleView: NSViewRepresentable {
    let onDrag: (NSEvent) -> Void
    var onTap: (() -> Void)?

    func makeNSView(context: Context) -> HandleView {
        HandleView(onDrag: onDrag, onTap: onTap)
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.onDrag = onDrag
        nsView.onTap = onTap
    }

    final class HandleView: NSView {
        var onDrag: (NSEvent) -> Void
        var onTap: (() -> Void)?

        init(onDrag: @escaping (NSEvent) -> Void, onTap: (() -> Void)?) {
            self.onDrag = onDrag
            self.onTap = onTap
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError()
        }

        override var acceptsFirstResponder: Bool {
            false
        }

        override var isFlipped: Bool {
            true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            // Only left-button is handled; let other buttons fall through.
            guard event.buttonNumber == 0 else {
                super.mouseDown(with: event)
                return
            }
            let start = NSEvent.mouseLocation
            // macOS drag threshold (a few px). Below this, the press is a click.
            let threshold: CGFloat = 4
            var didDrag = false

            // Track until mouseUp. If the cursor exits the threshold, hand off
            // to `window.performDrag` — which runs its own tracking loop and
            // moves the window. Otherwise it's a click → onTap on release.
            while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                if next.type == .leftMouseUp {
                    break
                }
                let now = NSEvent.mouseLocation
                if hypot(now.x - start.x, now.y - start.y) > threshold {
                    didDrag = true
                    onDrag(event)
                    break
                }
            }
            if !didDrag {
                onTap?()
            }
        }
    }
}

private func hypot(_ dx: CGFloat, _ dy: CGFloat) -> CGFloat {
    (dx * dx + dy * dy).squareRoot()
}
