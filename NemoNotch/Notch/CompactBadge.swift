import SwiftUI

struct CompactBadge: View {
    @Environment(MediaService.self) var mediaService
    @Environment(CalendarService.self) var calendarService
    @Environment(ClaudeCodeService.self) var claudeService
    @Environment(NotificationService.self) var notificationService
    let onTap: (Tab) -> Void
    let onOpenApp: (String) -> Void

    private enum BadgeInfo {
        case notification(String)  // bundleID
        case media
        case claude(ClaudeStatus, String?, Bool)  // status, currentTool, isPreToolUse
        case calendar
    }

    private var activeBadge: BadgeInfo? {
        // 1. Notification (highest priority)
        if let top = notificationService.badges.values.max(by: { $0.count < $1.count }) {
            return .notification(top.bundleID)
        }
        // 2. Claude Code
        if let session = claudeService.activeSession, session.status != .idle {
            return .claude(session.status, session.currentTool, session.isPreToolUse)
        }
        // 3. Media
        if mediaService.playbackState.isPlaying {
            return .media
        }
        // 4. Calendar
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
        HStack(spacing: 0) {
            leftIcon
            rightIcon
        }
    }

    var leftIcon: some View {
        Group {
            if let badge = activeBadge {
                Button {
                    switch badge {
                    case .notification(let bundleID): onOpenApp(bundleID)
                    default: onTap(tabFor(badge))
                    }
                } label: {
                    switch badge {
                    case .notification(let bundleID):
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
                    case .media:
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
                    case .claude(_, _, _):
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
                    case .calendar:
                        Image(systemName: "calendar")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .frame(width: 16, height: 16)
                .buttonStyle(.plain)
            }
        }
    }

    var rightIcon: some View {
        Group {
            if let badge = activeBadge {
                Button {
                    switch badge {
                    case .notification(let bundleID): onOpenApp(bundleID)
                    default: onTap(tabFor(badge))
                    }
                } label: {
                    switch badge {
                    case .notification:
                        Image(systemName: "bell.fill")
                            .modifier(PulseModifier(isActive: true))
                    case .media:
                        Image(systemName: "play.fill")
                    case .claude(let status, let tool, let isPre):
                        Image(systemName: ToolStyle.icon(tool))
                            .modifier(PulseModifier(isActive: status == .working))
                            .overlay {
                                if isPre {
                                    Circle()
                                        .stroke(ToolStyle.color(tool), lineWidth: 1.5)
                                        .frame(width: 16, height: 16)
                                        .modifier(GlowPulseModifier())
                                }
                            }
                    case .calendar:
                        Image(systemName: "clock.fill")
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(
                    badgeColor(badge).opacity(0.9)
                )
                .frame(width: 18, height: 18)
                .buttonStyle(.plain)
            }
        }
    }

    private func tabFor(_ badge: BadgeInfo) -> Tab {
        switch badge {
        case .notification: return .media  // fallback, won't be called
        case .media: return .media
        case .claude(_, _, _): return .claude
        case .calendar: return .calendar
        }
    }

    private func badgeColor(_ badge: BadgeInfo) -> Color {
        switch badge {
        case .notification: return .red
        case .media: return .white
        case .claude(_, let tool, _): return ToolStyle.color(tool)
        case .calendar: return .white
        }
    }

}
