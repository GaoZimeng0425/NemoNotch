import SwiftUI

struct CompactBadge: View {
    enum Side {
        case left
        case right
    }

    @Environment(MediaService.self) var mediaService
    @Environment(CalendarService.self) var calendarService
    @Environment(ClaudeCodeService.self) var claudeService
    @Environment(NotificationService.self) var notificationService
    @Environment(OpenClawService.self) var openClawService
    let side: Side
    let onTap: (Tab) -> Void
    let onOpenApp: (String) -> Void

    private enum BadgeInfo: Equatable {
        case notification(String)  // bundleID
        case media
        case claude(ClaudeStatus, String?, Bool)  // status, currentTool, isPreToolUse
        case openclaw(AgentState, String, String)  // state, emoji, name
        case calendar
    }

    @State private var shownBadge: BadgeInfo? = nil
    @State private var hideTask: Task<Void, Never>? = nil

    private var activeBadge: BadgeInfo? {
        // 1. Notification (needs attention)
        if let top = notificationService.badges.values.max(by: { $0.count < $1.count }) {
            return .notification(top.bundleID)
        }
        // 2. Active work (OpenClaw agent running)
        if let agent = openClawService.activeAgent {
            return .openclaw(agent.state, agent.emoji, agent.name)
        }
        // 3. Active work (Claude session running)
        if let session = claudeService.activeSession, session.status != .idle {
            return .claude(session.status, session.currentTool, session.isPreToolUse)
        }
        // 4. Passive states
        if mediaService.playbackState.isPlaying {
            return .media
        }
        // 5. Calendar
        if let next = calendarService.nextEvent, !next.isPast {
            let minutes = Int(next.startDate.timeIntervalSinceNow / 60)
            if minutes >= 0, minutes < 60 {
                return .calendar
            }
        }
        return nil
    }

    private func claudeColor(_ status: ClaudeStatus) -> Color {
        switch status {
        case .working: return .orange
        case .waiting: return .yellow
        case .idle: return .green
        }
    }

    var body: some View {
        Group {
            if let badge = shownBadge {
                Button {
                    switch badge {
                    case .notification(let bundleID): onOpenApp(bundleID)
                    default: onTap(tabFor(badge))
                    }
                } label: {
                    switch badge {
                    case .notification(let bundleID) where side == .left:
                        leftNotificationIcon(for: bundleID)
                    case .media where side == .left:
                        leftMediaIcon
                    case .claude(_, _, _) where side == .left:
                        leftClaudeIcon
                    case .openclaw where side == .left:
                        Text("🦞")
                            .font(.system(size: 11))
                    case .calendar where side == .left:
                        Image(systemName: "calendar")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    case .notification where side == .right:
                        Image(systemName: "bell.fill")
                            .modifier(PulseModifier(isActive: true))
                            .foregroundStyle(.red.opacity(0.9))
                    case .media where side == .right:
                        Image(systemName: "play.fill")
                            .foregroundStyle(.white.opacity(0.9))
                    case .claude(let status, let tool, let isPre) where side == .right:
                        Image(systemName: ToolStyle.icon(tool))
                            .foregroundStyle(ToolStyle.color(tool).opacity(0.9))
                            .modifier(PulseModifier(isActive: status == .working))
                            .overlay {
                                if isPre {
                                    Circle()
                                        .stroke(ToolStyle.color(tool), lineWidth: 1.5)
                                        .frame(width: 16, height: 16)
                                        .modifier(GlowPulseModifier())
                                }
                            }
                    case .openclaw(let state, let emoji, _) where side == .right:
                        Text(emoji)
                            .font(.system(size: 10))
                            .modifier(PulseModifier(isActive: state == .working || state == .toolCalling))
                    case .calendar where side == .right:
                        Image(systemName: "clock.fill")
                            .foregroundStyle(.white.opacity(0.9))
                    default:
                        EmptyView()
                    }
                }
                .frame(width: side == .left ? 16 : 18, height: side == .left ? 16 : 18)
                .buttonStyle(.plain)
            }
        }
        .onAppear { shownBadge = activeBadge }
        .onChange(of: activeBadge) { _, newBadge in
            if let newBadge {
                hideTask?.cancel()
                shownBadge = newBadge
            } else if shownBadge != nil {
                hideTask?.cancel()
                hideTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        shownBadge = nil
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func leftNotificationIcon(for bundleID: String) -> some View {
        if let item = notificationService.badges[bundleID] {
            ZStack(alignment: .bottomTrailing) {
                Image(nsImage: item.icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                if item.count > 0 {
                    Text("\(item.count)")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.red)
                        .clipShape(Capsule())
                        .frame(width: 12, height: 12)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 8, height: 8)
                }
            }
        }
    }

    @ViewBuilder
    private var leftMediaIcon: some View {
        if let data = mediaService.playbackState.artworkData,
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    @ViewBuilder
    private var leftClaudeIcon: some View {
        if let url = Bundle.main.url(forResource: "claude", withExtension: "webp"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "cpu")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private func tabFor(_ badge: BadgeInfo) -> Tab {
        switch badge {
        case .notification: return .media  // fallback, won't be called
        case .media: return .media
        case .claude(_, _, _): return .claude
        case .openclaw(_, _, _): return .openclaw
        case .calendar: return .calendar
        }
    }

    private func badgeColor(_ badge: BadgeInfo) -> Color {
        switch badge {
        case .notification: return .red
        case .media: return .white
        case .claude(_, let tool, _): return ToolStyle.color(tool)
        case .openclaw(let state, _, _): return state == .error ? .red : .orange
        case .calendar: return .white
        }
    }

}