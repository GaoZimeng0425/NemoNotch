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
    @Environment(\.aiStatusController) var controller

    private var isExpanded: Bool { controller?.isExpanded ?? false }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Layer 0 — the morphing background shape. Its frame + corner radius
            // are functions of `isExpanded`; the value-bound animation tweens
            // them (capsule pill ↔ panel 14pt rounded rect). This is the
            // "stretch" carrier, analogous to `NotchBackgroundView`.
            backgroundShape
                .animation(fabStateAnimation, value: isExpanded)
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
                    // The drag/click handle sits in `.overlay` (above the capsule
                    // content), NOT `.background`. SwiftUI's hosting view dispatches
                    // AppKit mouseDown to the topmost hit view first; an overlay
                    // NSView is above the content, so it reliably receives mouseDown.
                    // With `.background`, the SwiftUI content above would swallow the
                    // event (it has no gesture after we removed .onTapGesture, so
                    // SwiftUI would drop it instead of forwarding to the background).
                    // Kept INNERMOST so it follows the `allowsHitTesting` state below —
                    // outermost, it kept receiving drags from the panel's top-right
                    // corner even while expanded.
                    .overlay(
                        DragHandleView(
                            onDrag: { controller?.beginWindowDrag(with: $0) },
                            onTap: { controller?.toggleExpanded() }
                        )
                    )
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
            .shadow(color: .black.opacity(NotchConstants.openedShadowOpacity), radius: NotchConstants.openedShadowRadius)
    }

    /// Capsule width hugs its content; approximate for the collapsed shape.
    private var capsuleWidth: CGFloat {
        // "N running" + dot + padding. Wide enough for 2-digit counts.
        130
    }

    // MARK: - Layer 1: capsule content

    private var workingSessions: [AISessionState] {
        store.sortedSessions.filter { $0.status == .working }
    }

    private var workingCount: Int { workingSessions.count }

    private var capsuleContent: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [NotchTheme.accent, NotchTheme.accentHot],
                        center: .center, startRadius: 0, endRadius: 8
                    )
                )
                .frame(width: 10, height: 10)
                .shadow(color: NotchTheme.accent.opacity(0.7), radius: 6)
                .modifier(PulseModifier(isActive: true))
            Text("\(workingCount)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(NotchTheme.textPrimary)
            Text("running")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        // Fill the capsule width so content sits at the start (leading) edge,
        // matching the morphing background shape's footprint.
        .frame(width: capsuleWidth, alignment: .leading)
        .frame(height: NotchConstants.aiStatusFabCapsuleHeight)
        .contentShape(Capsule())
    }

    // MARK: - Layer 2: panel content (layout B: list + detail)

    @State private var selectedSessionId: String?

    private var selectedSession: AISessionState? {
        if let id = selectedSessionId, let s = store.get(id) { return s }
        return workingSessions.first
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
        }
        .frame(
            width: NotchConstants.aiStatusFabPanelWidth,
            height: NotchConstants.aiStatusFabPanelHeight
        )
        .clipShape(
            RoundedRectangle(cornerRadius: NotchConstants.aiStatusFabCornerRadius, style: .continuous)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(NotchTheme.accent)
                .frame(width: 8, height: 8)
                .shadow(color: NotchTheme.accent.opacity(0.6), radius: 4)
            Text("\(workingCount) running")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NotchTheme.textPrimary)
            Text("· AI sessions")
                .font(.system(size: 11))
                .foregroundStyle(NotchTheme.textSecondary)
            Spacer(minLength: 8)
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

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(workingSessions) { session in
                    let isSelected = session.id == selectedSession?.id
                    HStack(spacing: 7) {
                        statusDot(session.status)
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

    @ViewBuilder
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
                            expectedBundleId: session.launchingAppBundleId
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

    // MARK: - Status dot (traffic-light semantics)

    /// Green = working, yellow = waiting (input/approval), gray = idle.
    @ViewBuilder
    private func statusDot(_ status: ClaudeStatus) -> some View {
        let color = statusColor(status)
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.7), radius: 3)
    }

    private func statusColor(_ status: ClaudeStatus) -> Color {
        switch status {
        case .working: Color(red: 0.30, green: 0.85, blue: 0.45) // green
        case .waiting: Color(red: 0.98, green: 0.75, blue: 0.20) // yellow
        case .idle: NotchTheme.textTertiary // gray
        }
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
    var onTap: (() -> Void)? = nil

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
        required init?(coder: NSCoder) { fatalError() }

        override var acceptsFirstResponder: Bool { false }
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
                if next.type == .leftMouseUp { break }
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
