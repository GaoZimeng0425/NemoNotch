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

            // Layer 1 — capsule content (shown when collapsed). Always present;
            // faded/scaled out when expanding so it reads as "growing into" the
            // panel, like `NotchView`'s CompactBadgesView.
            capsuleContent
                .opacity(isExpanded ? 0 : 1)
                .scaleEffect(isExpanded ? 0.8 : 1, anchor: .topTrailing)
                .allowsHitTesting(!isExpanded)
                .animation(fabStateAnimation, value: isExpanded)
                // The whole capsule is the drag handle in collapsed state.
                .background(DragHandleView { controller?.beginWindowDrag(with: $0) })
                .zIndex(1)

            // Layer 2 — panel content (shown when expanded). Always present;
            // faded/scaled in on expand, like `NotchView`'s contentPanel.
            panelContent
                .opacity(isExpanded ? 1 : 0)
                .scaleEffect(isExpanded ? 1 : 0.85, anchor: .topTrailing)
                .allowsHitTesting(isExpanded)
                .animation(fabStateAnimation, value: isExpanded)
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

    // MARK: - Layer 0: background shape

    private var backgroundShape: some View {
        let shapeW = isExpanded
            ? NotchConstants.aiStatusFabPanelWidth
            : capsuleWidth
        let shapeH = isExpanded
            ? NotchConstants.aiStatusFabPanelHeight
            : NotchConstants.aiStatusFabCapsuleHeight
        // Collapsed → radius = height/2 yields a pill; expanded → 14pt.
        let radius: CGFloat = isExpanded
            ? NotchConstants.aiStatusFabCornerRadius
            : NotchConstants.aiStatusFabCapsuleHeight / 2
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [NotchTheme.panelRaised, NotchTheme.panelBase],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(width: shapeW, height: shapeH)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
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
        }
        .padding(.horizontal, 12)
        .frame(height: NotchConstants.aiStatusFabCapsuleHeight)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Capsule())
        .onTapGesture { controller?.toggleExpanded() }
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
        return HStack(spacing: 3) {
            sourceIcon(source, size: 10)
            Text(sourceLabel(source))
        }
        .font(.system(size: 9, weight: .bold, design: .rounded))
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.14))
        .clipShape(Capsule(style: .continuous))
    }

    private func sourceLabel(_ source: AISource) -> String {
        switch source {
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .opencode: "opencode"
        case .zcode: "zcode"
        }
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
/// panel's header. Its `mouseDown` forwards the event to `onDrag`, which calls
/// `AIStatusWindowController.beginWindowDrag(with:)` → `window.performDrag`.
///
/// This is the idiomatic SwiftUI→AppKit bridge for `performDrag`: SwiftUI's
/// `DragGesture` doesn't expose the underlying `NSEvent`, but `performDrag`
/// needs one to run AppKit's drag-tracking loop. `mouseDown` is the only entry
/// point that hands us the real event.
///
/// Installed as a `.background`, so SwiftUI's hosted controls render in a layer
/// above this view and keep receiving their taps — AppKit routes a click to the
/// topmost hit view first, and the SwiftUI hosting view claims points that land
/// on its interactive content. This view only sees `mouseDown` for empty
/// padding regions.
///
/// `acceptsFirstMouse` returns true so a click onto the FAB (a non-activating
/// panel) starts the drag immediately without a preliminary focus click.
private struct DragHandleView: NSViewRepresentable {
    let onDrag: (NSEvent) -> Void

    func makeNSView(context: Context) -> HandleView {
        HandleView(onDrag: onDrag)
    }

    func updateNSView(_ nsView: HandleView, context: Context) {
        nsView.onDrag = onDrag
    }

    final class HandleView: NSView {
        var onDrag: (NSEvent) -> Void

        init(onDrag: @escaping (NSEvent) -> Void) {
            self.onDrag = onDrag
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var acceptsFirstResponder: Bool { false }
        override var isFlipped: Bool { true }
        // Non-activating panel: accept the first mouse so the drag starts
        // immediately without a preliminary focus click.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // Only left-button starts a window drag; let other buttons fall
            // through to default handling.
            guard event.buttonNumber == 0 else {
                super.mouseDown(with: event)
                return
            }
            onDrag(event)
        }
    }
}
