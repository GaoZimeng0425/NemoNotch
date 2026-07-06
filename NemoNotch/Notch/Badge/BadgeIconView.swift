import SwiftUI

enum BadgeRenderStyle {
    case compactLeft
    case compactRight
}

// MARK: - BadgeIconView

struct BadgeIconView: View {
    let item: BadgeItem
    let style: BadgeRenderStyle
    let notificationService: NotificationService
    let mediaService: MediaService
    let pomodoroService: PomodoroTimerService

    var body: some View {
        switch item {
        case let .notification(bundleID, count):
            notificationBadge(bundleID: bundleID, count: count)
        case .media:
            mediaBadge
        case let .ai(source, status, tool, waitingApproval, _):
            aiBadge(source: source, status: status, tool: tool, waitingApproval: waitingApproval)
        case let .agents(_, state, emoji):
            agentsBadge(state: state, emoji: emoji)
        case .calendar:
            calendarBadge
        case let .pomodoro(phase):
            pomodoroBadge(phase: phase)
        }
    }

    // MARK: - Notification

    @ViewBuilder
    private func notificationBadge(bundleID: String, count: Int) -> some View {
        switch style {
        case .compactLeft:
            if let data = notificationService.badges[bundleID] {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: data.icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 2)
                            .padding(.vertical, 0.5)
                            .background(.red)
                            .clipShape(Capsule())
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                    }
                }
            }
        case .compactRight:
            Image(systemName: "bell.fill")
                .foregroundStyle(.red.opacity(0.9))
                .frame(width: 14, height: 14)
                .modifier(PulseModifier(isActive: true))
        }
    }

    // MARK: - Media

    @ViewBuilder
    private var mediaBadge: some View {
        let isPlaying = mediaService.playbackState.isPlaying
        switch style {
        case .compactLeft:
            VinylDiscView(
                isPlaying: isPlaying,
                artworkData: mediaService.playbackState.artworkData,
                appIcon: mediaService.appIcon,
                size: 20
            )
        case .compactRight:
            AudioEqualizerView(isActive: isPlaying, maxHeight: 10, barWidth: 1.5, color: NotchTheme.accent)
        }
    }

    // MARK: - AI

    @ViewBuilder
    private func aiBadge(source: AISource, status: ClaudeStatus, tool: String?, waitingApproval: Bool) -> some View {
        switch style {
        case .compactLeft:
            aiSourceIcon(source: source, status: status)
        case .compactRight:
            if waitingApproval {
                Circle()
                    .fill(NotchTheme.accent.opacity(0.25))
                    .frame(width: 18, height: 18)
                    .overlay {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(NotchTheme.accent)
                    }
                    .modifier(PulseModifier(isActive: true))
            } else if status == .working {
                ProcessingSpinner(color: source == .claude ? ToolStyle.color(tool) : .blue)
            } else if status == .waiting {
                Image(systemName: "questionmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .frame(width: 18, height: 18)
                    .modifier(PulseModifier(isActive: true))
            } else {
                Circle()
                    .fill((source == .claude ? ToolStyle.color(tool) : Color.blue).opacity(0.7))
                    .frame(width: 8, height: 8)
                    .frame(width: 18, height: 18)
            }
        }
    }

    @ViewBuilder
    private func aiSourceIcon(source: AISource, status: ClaudeStatus) -> some View {
        switch source {
        case .claude:
            ClaudeCrabIcon(size: 14, animateLegs: status == .working)
        case .gemini:
            Image(systemName: "sparkle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.blue)
        case .opencode:
            OpencodeLogoIcon(size: 13, color: Color(red: 0.55, green: 0.78, blue: 0.55))
        }
    }

    // MARK: - Agents

    @ViewBuilder
    private func agentsBadge(state: AgentMonitorState, emoji: String) -> some View {
        switch style {
        case .compactLeft:
            if emoji.isEmpty {
                Image("HermesIcon")
                    .renderingMode(.original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 13, height: 13)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            } else {
                Text(emoji)
                    .font(.system(size: 10))
            }
        case .compactRight:
            Image(systemName: state.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(agentMonitorStateColor(state))
                .frame(width: 14, height: 14)
                .modifier(PulseModifier(isActive: state == .working || state == .toolCalling))
        }
    }

    private func agentMonitorStateColor(_ state: AgentMonitorState) -> Color {
        switch state {
        case .idle: NotchTheme.textSecondary
        case .working: .blue
        case .speaking: .green
        case .toolCalling: NotchTheme.accent
        case .error: .red
        }
    }

    // MARK: - Calendar

    @ViewBuilder
    private var calendarBadge: some View {
        switch style {
        case .compactLeft:
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NotchTheme.textPrimary)
        case .compactRight:
            Image(systemName: "clock.fill")
                .foregroundStyle(NotchTheme.textPrimary)
                .frame(width: 14, height: 14)
        }
    }

    // MARK: - Pomodoro

    @ViewBuilder
    private func pomodoroBadge(phase: PomodoroPhase) -> some View {
        switch style {
        case .compactLeft:
            Text("🍅")
                .font(.system(size: 14))
                .opacity(emojiOpacity)
                .modifier(PomodoroPulseModifier(token: pomodoroService.pulseToken))
        case .compactRight:
            PomodoroPieView(
                remainingFraction: pomodoroService.remainingFraction,
                phase: phase,
                style: .badge
            )
            .opacity(piePausedOpacity)
            .modifier(PomodoroPulseModifier(token: pomodoroService.pulseToken))
        }
    }

    private var emojiOpacity: Double {
        if case .paused = pomodoroService.state { return 0.55 }
        return 1.0
    }

    private var piePausedOpacity: Double {
        if case .paused = pomodoroService.state { return 0.7 }
        return 1.0
    }
}

// MARK: - CompactBadgesView

struct CompactBadgesView: View {
    let cluster: BadgeCluster
    let shownHasActiveBadge: Bool
    let notchLeftEdge: CGFloat
    let notchRightEdge: CGFloat
    let notchCenterY: CGFloat
    let onBadgeTap: (BadgeItem) -> Void
    let notificationService: NotificationService
    let mediaService: MediaService
    let pomodoroService: PomodoroTimerService

    /// Tapping anywhere opens the highest-priority group's tab.
    private var primary: BadgeItem? {
        cluster.groups.first?.representative
    }

    var body: some View {
        let spread: CGFloat = shownHasActiveBadge ? NotchConstants.badgeSpread : 0
        ZStack {
            leftFan(spread: spread)
            rightFan(spread: spread)
        }
        .opacity(shownHasActiveBadge ? 1 : 0)
        .animation(
            .spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce),
            value: spread
        )
        .animation(
            .spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce),
            value: shownHasActiveBadge
        )
    }

    // Left: overlapping logos. Highest priority (index 0) hugs the notch and is
    // frontmost; lower-priority logos fan leftward behind it. A trailing "+K"
    // chip sits at the far (backmost) end when groups overflowed.
    @ViewBuilder
    private func leftFan(spread: CGFloat) -> some View {
        ForEach(Array(cluster.groups.enumerated()), id: \.element.id) { index, group in
            Button { primary.map(onBadgeTap) } label: {
                BadgeIconView(
                    item: group.representative, style: .compactLeft,
                    notificationService: notificationService,
                    mediaService: mediaService,
                    pomodoroService: pomodoroService
                )
            }
            .buttonStyle(.plain)
            .zIndex(Double(cluster.groups.count - index))
            .position(
                x: notchLeftEdge - spread - CGFloat(index) * NotchConstants.badgeStackStep,
                y: notchCenterY
            )
            .transition(.opacity.combined(with: .offset(x: NotchConstants.badgeSpread)))
        }
        if cluster.overflow > 0 {
            Button { primary.map(onBadgeTap) } label: {
                BadgeCountChip(text: "+\(cluster.overflow)")
            }
            .buttonStyle(.plain)
            .position(
                x: notchLeftEdge - spread - CGFloat(cluster.groups.count) * NotchConstants.badgeStackStep,
                y: notchCenterY
            )
            .transition(.opacity.combined(with: .offset(x: NotchConstants.badgeSpread)))
        }
    }

    // Right: statuses in priority order, highest hugging the notch. A group of
    // more than one (same-app instances) shows just its count, centered in the
    // slot, in place of the status indicator.
    private func rightFan(spread: CGFloat) -> some View {
        ForEach(Array(cluster.groups.enumerated()), id: \.element.id) { index, group in
            Button { primary.map(onBadgeTap) } label: {
                if group.count > 1 {
                    BadgeCountChip(text: "\(group.count)", fontSize: 10)
                } else {
                    BadgeIconView(
                        item: group.representative, style: .compactRight,
                        notificationService: notificationService,
                        mediaService: mediaService,
                        pomodoroService: pomodoroService
                    )
                }
            }
            .buttonStyle(.plain)
            .position(
                x: notchRightEdge + spread + CGFloat(index) * NotchConstants.badgeStatusStep,
                y: notchCenterY
            )
            .transition(.opacity.combined(with: .offset(x: -NotchConstants.badgeSpread)))
        }
    }
}

// MARK: - BadgeCountChip

/// Small rounded count pill, matching the notification badge count style.
/// `fontSize` defaults to the compact overlay size; the right-fan standalone
/// count passes a larger value so it reads as the slot's primary content.
private struct BadgeCountChip: View {
    let text: String
    var fontSize: CGFloat = 7

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, fontSize < 9 ? 2 : 4)
            .padding(.vertical, fontSize < 9 ? 0.5 : 1)
            .background(NotchTheme.accent)
            .clipShape(Capsule())
    }
}

// MARK: - PomodoroPulseModifier

private struct PomodoroPulseModifier: ViewModifier {
    let token: UUID
    @State private var opacity: Double = 1.0

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .onChange(of: token) { _, _ in
                withAnimation(.easeInOut(duration: 0.15).repeatCount(4, autoreverses: true)) {
                    opacity = 0.3
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        opacity = 1.0
                    }
                }
            }
    }
}
