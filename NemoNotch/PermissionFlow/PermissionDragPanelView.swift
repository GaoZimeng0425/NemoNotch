import AppKit
import SwiftUI

/// Whether the guide is still waiting for the drop or has detected the grant.
enum PermissionGuideState {
    case waiting
    case granted
}

/// Contents of the floating guide: what to drag, where to drop it, and what to
/// do after. Deliberately compact — it sits over the user's desktop.
struct PermissionDragPanelView: View {
    let pane: PermissionPane
    let appName: String
    let appIcon: NSImage
    let appURL: URL
    let state: PermissionGuideState
    let onClose: () -> Void

    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            dragRow
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 384)
        .background(panelBackground)
        .onAppear { pulse = true }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: state == .granted ? "checkmark.seal.fill" : "lock.shield")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state == .granted ? .green : NotchTheme.accent)

            Text(state == .granted
                ? String(localized: "permission.flow.granted")
                : String(localized: "permission.flow.title"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NotchTheme.textTertiary)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(NotchTheme.surfaceEmphasis))
            }
            .buttonStyle(.plain)
            .help("permission.flow.close_help")
        }
    }

    private var dragRow: some View {
        HStack(spacing: 12) {
            ZStack {
                if state == .waiting {
                    Circle()
                        .stroke(NotchTheme.accent.opacity(0.55), lineWidth: 1.5)
                        .frame(width: 62, height: 62)
                        .scaleEffect(pulse ? 1.12 : 1.0)
                        .opacity(pulse ? 0.15 : 0.65)
                        .animation(
                            .easeInOut(duration: 1.25).repeatForever(autoreverses: true),
                            value: pulse
                        )
                }
                DraggableAppIcon(appURL: appURL, appIcon: appIcon) { _ in }
            }
            .frame(width: 64, height: 64)

            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textTertiary)

            VStack(alignment: .leading, spacing: 3) {
                Text("permission.flow.drag_hint")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("permission.flow.drag_target \(pane.localizedTitle)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    /// Branches rather than a ternary: `Text("key \(value)")` only resolves to
    /// `LocalizedStringKey` when the literal is passed directly. Folding the two
    /// cases into one ternary would infer `String` and silently drop localization.
    private var footer: some View {
        Group {
            if state == .granted {
                Text("permission.flow.granted_detail \(appName)")
            } else {
                Text("permission.flow.after_hint \(appName)")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(NotchTheme.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(NotchTheme.panelBase.opacity(0.94))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(NotchTheme.strokeStrong, lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
    }
}

// MARK: - AppKit drag source bridge

/// Wraps the `NSView` drag source so SwiftUI can host it. The drag cannot be
/// expressed in pure SwiftUI — `beginDraggingSession(with:event:source:)`
/// requires a real `NSView` event.
private struct DraggableAppIcon: NSViewRepresentable {
    let appURL: URL
    let appIcon: NSImage
    let onDragEnded: (Bool) -> Void

    func makeNSView(context: Context) -> DraggableAppIconView {
        DraggableAppIconView(appURL: appURL, icon: appIcon)
    }

    func updateNSView(_ nsView: DraggableAppIconView, context: Context) {
        nsView.onDragEnded = onDragEnded
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: DraggableAppIconView,
        context: Context
    ) -> CGSize? {
        nsView.intrinsicContentSize
    }
}
