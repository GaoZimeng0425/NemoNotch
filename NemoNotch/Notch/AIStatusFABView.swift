import AppKit
import SwiftUI

/// The floating AI-status button. Collapsed = draggable capsule showing the
/// running-session count; expanded = a list+detail panel.
struct AIStatusFABView: View {
    @Environment(AISessionStore.self) var store
    @Environment(\.aiStatusController) var controller

    var body: some View {
        if controller?.isExpanded == true {
            panel
        } else {
            capsule
        }
    }

    // MARK: - Derived

    private var workingSessions: [AISessionState] {
        store.sortedSessions.filter { $0.status == .working }
    }

    private var workingCount: Int { workingSessions.count }

    // MARK: - Collapsed capsule

    private var capsule: some View {
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
        .padding(.vertical, 8)
        .fixedSize(horizontal: true, vertical: false)
        .background(.black)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(NotchTheme.stroke, lineWidth: 0.6))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
        .contentShape(Capsule())
        .onTapGesture { controller?.toggleExpanded() }
    }

    // MARK: - Expanded panel (layout B: list + detail)

    @State private var selectedSessionId: String?

    private var selectedSession: AISessionState? {
        if let id = selectedSessionId, let s = store.get(id) { return s }
        return workingSessions.first
    }

    private var panel: some View {
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
        .frame(width: NotchConstants.aiStatusFabPanelWidth)
        .background(
            RoundedRectangle(cornerRadius: NotchConstants.aiStatusFabCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [NotchTheme.panelRaised, NotchTheme.panelBase],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: NotchConstants.aiStatusFabCornerRadius, style: .continuous)
                .stroke(NotchTheme.stroke, lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(NotchConstants.openedShadowOpacity), radius: NotchConstants.openedShadowRadius)
        .padding(NotchConstants.openedShadowRadius + 6) // room for shadow blur
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
        // Expanded-state drag handle. In expanded state
        // `isMovableByWindowBackground` is false (so list-row taps don't start a
        // drag); dragging is moved here, to the header, via performDrag. The
        // NSView's mouseDown forwards the event to the controller, which calls
        // `window.performDrag(with:)`. The collapse button sits above this
        // background and still receives its taps normally.
        .background(DragHandleView { controller?.beginWindowDrag(with: $0) })
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(workingSessions) { session in
                    let isSelected = session.id == selectedSession?.id
                    HStack(spacing: 7) {
                        Circle()
                            .fill(NotchTheme.accent)
                            .frame(width: 6, height: 6)
                            .shadow(color: NotchTheme.accent.opacity(0.7), radius: 3)
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

    // MARK: - Source icon (inlined switch; reuses the public icon components)

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

// MARK: - Header drag handle

/// Transparent AppKit view placed behind the expanded panel's header. Its
/// `mouseDown` forwards the event to `onDrag`, which calls
/// `AIStatusWindowController.beginWindowDrag(with:)` → `window.performDrag`.
///
/// This is the idiomatic SwiftUI→AppKit bridge for `performDrag`: SwiftUI's
/// `DragGesture` doesn't expose the underlying `NSEvent`, but `performDrag`
/// needs one to run AppKit's drag-tracking loop. `mouseDown` is the only entry
/// point that hands us the real event.
///
/// Installed as a `.background` of the header `HStack`, so SwiftUI's hosted
/// controls (the collapse button) render in a layer above this view and keep
/// receiving their taps — AppKit routes a click to the topmost hit view first,
/// and the SwiftUI hosting view claims points that land on its interactive
/// content. This view only sees `mouseDown` for the empty header padding.
///
/// `acceptsFirstMouse` returns true so a click onto the header (a non-activating
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
