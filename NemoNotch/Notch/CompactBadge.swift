import SwiftUI

struct CompactBadge: View {
    let mediaService: MediaService
    let calendarService: CalendarService
    let claudeService: ClaudeCodeService
    let onTap: (Tab) -> Void

    private var activeBadge: (tab: Tab, appIcon: String, statusIcon: String, isPulsing: Bool)? {
        if claudeService.activeSession?.status == .working {
            return (.claude, "cpu", "gearshape.fill", true)
        }
        if mediaService.playbackState.isPlaying {
            return (.media, "music.note", "play.fill", false)
        }
        if let next = calendarService.nextEvent, !next.isPast {
            let minutes = Int(next.startDate.timeIntervalSinceNow / 60)
            if minutes >= 0, minutes < 60 {
                return (.calendar, "calendar", "clock.fill", false)
            }
        }
        return nil
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
                Button { onTap(badge.tab) } label: {
                    Image(systemName: badge.appIcon)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
    }

    var rightIcon: some View {
        Group {
            if let badge = activeBadge {
                Button { onTap(badge.tab) } label: {
                    Image(systemName: badge.statusIcon)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.8))
                        .modifier(PulseModifier(isActive: badge.isPulsing))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
