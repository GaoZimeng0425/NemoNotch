import SwiftUI

struct CompactBadge: View {
    let mediaService: MediaService
    let calendarService: CalendarService
    let claudeService: ClaudeCodeService
    let notificationService: NotificationService
    let onTap: (Tab) -> Void
    let onOpenApp: (String) -> Void

    private enum BadgeInfo {
        case notification(String)  // bundleID
        case media
        case claude(ClaudeStatus, String?)  // status, currentTool
        case calendar
    }

    private var activeBadge: BadgeInfo? {
        // 1. Notification (highest priority)
        if let top = notificationService.badges.values.max(by: { $0.count < $1.count }) {
            return .notification(top.bundleID)
        }
        // 2. Claude Code
        if let session = claudeService.activeSession, session.status != .idle {
            return .claude(session.status, session.currentTool)
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
                    case .claude(_, _):
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
                    case .claude(let status, _):
                        Image(systemName: status == .working ? "gearshape.fill" : "exclamationmark.circle.fill")
                            .modifier(PulseModifier(isActive: status == .working))
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
        case .claude(_, _): return .claude
        case .calendar: return .calendar
        }
    }

    private func badgeColor(_ badge: BadgeInfo) -> Color {
        switch badge {
        case .notification: return .red
        case .media: return .white
        case .claude(let status, _): return claudeColor(status)
        case .calendar: return .white
        }
    }

    private func toolIcon(_ tool: String?) -> String {
        guard let tool else { return "gearshape.fill" }
        if tool.hasPrefix("Read") || tool.hasPrefix("Grep") || tool == "Glob" {
            return "doc.text.magnifyingglass"
        }
        if tool.hasPrefix("Write") || tool == "Edit" {
            return "pencil"
        }
        if tool == "Bash" {
            return "terminal"
        }
        if tool == "Agent" {
            return "person.wave.2"
        }
        if tool.hasPrefix("Web") {
            return "globe"
        }
        return "gearshape.fill"
    }
}
