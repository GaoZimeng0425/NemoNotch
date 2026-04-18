import SwiftUI

struct CompactBadge: View {
    let mediaService: MediaService
    let calendarService: CalendarService
    let claudeService: ClaudeCodeService
    let onTap: (Tab) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if claudeService.activeSession?.status == .working {
                badgeButton(tab: .claude) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .modifier(PulseModifier(isActive: true))
                        Text(truncate(claudeService.activeSession?.currentTool ?? "working", limit: 12))
                            .font(.system(size: 10))
                    }
                }
            }

            if mediaService.playbackState.isPlaying {
                badgeButton(tab: .media) {
                    HStack(spacing: 4) {
                        Image(systemName: "music.note")
                            .font(.system(size: 9))
                        Text(truncate(mediaService.playbackState.title, limit: 10))
                            .font(.system(size: 10))
                    }
                }
            }

            if let next = calendarService.nextEvent, !next.isPast {
                let minutes = Int(next.startDate.timeIntervalSinceNow / 60)
                if minutes >= 0 && minutes < 60 {
                    badgeButton(tab: .calendar) {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                                .font(.system(size: 9))
                            Text("\(minutes)分钟后")
                                .font(.system(size: 10))
                        }
                    }
                }
            }
        }
    }

    private func badgeButton(tab: Tab, @ViewBuilder content: () -> some View) -> some View {
        Button {
            onTap(tab)
        } label: {
            content()
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.6))
        .clipShape(Capsule())
    }

    private func truncate(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…"
    }
}
