import SwiftUI

// MARK: - Pure model (unit-tested)

/// Row shown on the lock-screen AI panel. Built by `LockScreenAIPanelModel`
/// from store sessions so the filtering/ordering logic stays unit-testable
/// without AppKit.
struct LockScreenAIPanelItem: Equatable, Identifiable {
    let id: String
    let source: AISource
    let title: String
    let status: LockScreenAIPanelStatus
    let contextPercent: Double
    let runningSeconds: TimeInterval
}

enum LockScreenAIPanelStatus: Equatable {
    case running
    case compacting
    case awaitingApproval
}

enum LockScreenAIPanelModel {
    /// Keep the card a predictable height on the lock screen; overflow folds
    /// into a "+N" footer.
    static let maxRows = 5

    /// Panel shows sessions that are actively doing something (running,
    /// compacting) or blocked on the user (awaiting approval). Idle, finished,
    /// and waiting-for-input sessions are not "processes" and stay hidden.
    static func shouldShow(sessions: [AISessionState], isLocked: Bool, enabled: Bool) -> Bool {
        guard enabled, isLocked else { return false }
        return sessions.contains { $0.phase.isActive }
    }

    /// Awaiting-approval rows first (they need the user), then most-recently
    /// active, capped at `maxRows`.
    static func makeItems(from sessions: [AISessionState], now: Date = Date()) -> [LockScreenAIPanelItem] {
        sessions
            .filter { $0.phase.isActive }
            .map { session in
                LockScreenAIPanelItem(
                    id: session.id,
                    source: session.source,
                    title: displayTitle(for: session),
                    status: status(for: session.phase),
                    contextPercent: session.contextPercent,
                    runningSeconds: max(0, now.timeIntervalSince(session.sessionStart))
                )
            }
            .sorted { lhs, rhs in
                if lhs.status == .awaitingApproval, rhs.status != .awaitingApproval { return true }
                if lhs.status != .awaitingApproval, rhs.status == .awaitingApproval { return false }
                return lhs.runningSeconds > rhs.runningSeconds
            }
            .prefix(maxRows)
            .map { $0 }
    }

    /// Prefer the project folder name (short, scannable on a glance) and fall
    /// back to the session's display title, truncated for a single line.
    static func displayTitle(for session: AISessionState) -> String {
        if let folder = session.projectFolder, !folder.isEmpty { return folder }
        let title = session.displayTitle
        return title.count > 28 ? String(title.prefix(28)) + "…" : title
    }

    static func status(for phase: SessionPhase) -> LockScreenAIPanelStatus {
        switch phase {
        case .waitingForApproval: .awaitingApproval
        case .compacting: .compacting
        default: .running
        }
    }

    /// Compact elapsed label: 45s → "45s", 12min → "12m", 3.2h → "3.2h".
    static func elapsedText(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "\(Int(seconds))s"
        case ..<3600: "\(Int(seconds) / 60)m"
        default: String(format: "%.1fh", seconds / 3600)
        }
    }
}

// MARK: - View

/// Dark card listing active AI sessions while the Mac is locked. Hosted by
/// `LockScreenAIPanelWindow` (display-only, ignored mouse events) — the lock
/// screen belongs to the system, so the card never takes interaction.
struct LockScreenAIPanelView: View {
    @Environment(AISessionStore.self) private var store
    @Environment(AppSettings.self) private var appSettings

    var body: some View {
        // 1s cadence refreshes the elapsed labels; the window (and this whole
        // SwiftUI tree) only exists while the Mac is locked, so the timer
        // never ticks on an unlocked desktop.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let items = LockScreenAIPanelModel.makeItems(from: store.sortedSessions, now: context.date)
            card(items: items, now: context.date)
        }
    }

    private func card(items: [LockScreenAIPanelItem], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(count: items.count)

            ForEach(items) { item in
                row(item)
            }

            if items.count == LockScreenAIPanelModel.maxRows {
                let activeCount = store.sortedSessions.filter { $0.phase.isActive }.count
                if activeCount > items.count {
                    Text("lockscreen.ai.more \(activeCount - items.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NotchTheme.textTertiary)
                        .padding(.leading, 2)
                }
            }
        }
        .padding(14)
        .frame(width: 312, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(NotchTheme.panelBase)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .animation(.snappy(duration: 0.25), value: items)
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.accentText)
            Text("lockscreen.ai.title")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(NotchTheme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.10)))
        }
        .padding(.bottom, 2)
    }

    private func row(_ item: LockScreenAIPanelItem) -> some View {
        HStack(spacing: 10) {
            sourceChip(item)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(NotchTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(statusLabel(item.status))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(statusColor(item.status))
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(LockScreenAIPanelModel.elapsedText(item.runningSeconds))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(NotchTheme.textSecondary)
                if item.contextPercent > 0 {
                    Text("\(Int(item.contextPercent * 100))%")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(NotchTheme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(item.status == .awaitingApproval
                    ? NotchTheme.accent.opacity(0.14)
                    : Color.white.opacity(0.05))
        )
    }

    /// Source logo in a tinted chip with a live-status dot — mirrors the
    /// `sourceMark` treatment on `AIChatTab` (third copy after
    /// `CompletionToastView`; the switch is trivially small per copy).
    private func sourceChip(_ item: LockScreenAIPanelItem) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(sourceTint(item.source).opacity(0.16))
            .frame(width: 28, height: 28)
            .overlay {
                sourceIcon(item.source)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(statusColor(item.status))
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                    .offset(x: 3, y: 3)
            }
    }

    @ViewBuilder
    private func sourceIcon(_ source: AISource) -> some View {
        switch source {
        case .claude:
            ClaudeCrabIcon(size: 14, color: sourceTint(source))
        case .gemini:
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(sourceTint(source))
        case .opencode:
            OpencodeLogoIcon(size: 14, color: sourceTint(source))
        case .zcode:
            ZcodeLogoIcon(size: 14, color: sourceTint(source))
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

    private func statusLabel(_ status: LockScreenAIPanelStatus) -> String {
        switch status {
        case .running: String(localized: "lockscreen.ai.status.running")
        case .compacting: String(localized: "lockscreen.ai.status.compacting")
        case .awaitingApproval: String(localized: "lockscreen.ai.status.awaiting_approval")
        }
    }

    private func statusColor(_ status: LockScreenAIPanelStatus) -> Color {
        switch status {
        case .running: NotchTheme.accentText
        case .compacting: NotchTheme.textSecondary
        case .awaitingApproval: NotchTheme.accent
        }
    }
}
