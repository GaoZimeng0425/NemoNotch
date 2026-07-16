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
        let _ = PerfProbe.hit("BadgeIconView.body")
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
            AudioEqualizerView(
                isActive: isPlaying,
                maxHeight: 10,
                barWidth: 1.5,
                color: mediaService.artworkAccent ?? NotchTheme.accent
            )
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
        case .zcode:
            ZcodeLogoIcon(size: 13, color: Color(red: 0.11, green: 0.44, blue: 0.96))
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
        if case .paused = pomodoroService.state {
            return 0.55
        }
        return 1.0
    }

    private var piePausedOpacity: Double {
        if case .paused = pomodoroService.state {
            return 0.7
        }
        return 1.0
    }
}

// MARK: - CompactBadgesView

struct CompactBadgesView: View {
    let cluster: BadgeCluster
    let shownHasActiveBadge: Bool
    /// Total width of the collapsed black shape (already badge-expanded).
    let notchClosedWidth: CGFloat
    /// Width of the central notch core the two columns straddle; the middle
    /// spacer is exactly this wide so the left/right coins sit just outside it.
    let notchCoreWidth: CGFloat
    let onBadgeTap: (BadgeItem) -> Void
    let notificationService: NotificationService
    let mediaService: MediaService
    let pomodoroService: PomodoroTimerService

    /// Tapping anywhere opens the highest-priority group's tab.
    private var primary: BadgeItem? {
        cluster.groups.first?.representative
    }

    /// Negative spacing for the per-column coin HStack. Coins are `coinDiameter`
    /// wide; stepping them `badgeStackStep` apart means each reveals that much
    /// of the coin beneath → overlap is `coinDiameter - badgeStackStep`.
    private var coinOverlap: CGFloat {
        NotchConstants.badgeCoinDiameter - NotchConstants.badgeStackStep
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left column: logos, trailing-aligned so the highest-priority coin
            // (index 0, first in the HStack) hugs the notch on its right edge.
            leftColumn
                .frame(maxWidth: .infinity, alignment: .trailing)

            // Middle column: clear spacer exactly as wide as the notch core, so
            // the left/right coins straddle it like the expanded chin bar does.
            Color.clear
                .frame(width: notchCoreWidth, height: NotchConstants.badgeCoinDiameter)

            // Right column: statuses, leading-aligned so index 0 hugs the notch
            // on its left edge.
            rightColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: notchClosedWidth)
        .opacity(shownHasActiveBadge ? 1 : 0)
        .animation(
            .spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce),
            value: shownHasActiveBadge
        )
        .animation(
            .spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce),
            value: cluster
        )
    }

    // MARK: - Left column (logos)

    // Coins stack with negative spacing (`-coinOverlap`); index 0 is the
    // highest priority and sits frontmost. A trailing "+K" chip sits at the far
    // (backmost) end when groups overflowed. Each coin slides in from the notch
    // side (positive x) and settles leftward.
    @ViewBuilder
    private var leftColumn: some View {
        HStack(spacing: -coinOverlap) {
            ForEach(Array(cluster.groups.enumerated()), id: \.element.id) { index, group in
                Button { primary.map(onBadgeTap) } label: {
                    BadgeIconView(
                        item: group.representative, style: .compactLeft,
                        notificationService: notificationService,
                        mediaService: mediaService,
                        pomodoroService: pomodoroService
                    )
                    .coinBackground()
                }
                .buttonStyle(.plain)
                .zIndex(Double(cluster.groups.count - index))
                .transition(.opacity.combined(with: .offset(x: NotchConstants.badgeStackStep)))
            }
            if cluster.overflow > 0 {
                Button { primary.map(onBadgeTap) } label: {
                    BadgeCountChip(text: "+\(cluster.overflow)")
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .offset(x: NotchConstants.badgeStackStep)))
            }
        }
    }

    // MARK: - Right column (statuses)

    // Mirror of the left column. A group of more than one (same-app instances)
    // shows just its count in place of the status indicator. Each coin slides
    // in from the notch side (negative x) and settles rightward.
    @ViewBuilder
    private var rightColumn: some View {
        HStack(spacing: -coinOverlap) {
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
                        .coinBackground()
                    }
                }
                .buttonStyle(.plain)
                .zIndex(Double(cluster.groups.count - index))
                .transition(.opacity.combined(with: .offset(x: -NotchConstants.badgeStackStep)))
            }
        }
    }
}

// MARK: - CoinBackground

/// Frosted disc behind a compact badge so overlapping coins read as distinct
/// layered chips. `ultraThinMaterial` blurs the content beneath (menu bar,
/// wallpaper, the coin stacked behind), so a lone coin still sees through while
/// stacked coins separate cleanly via the `stroke` rim and soft shadow.
private struct CoinBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(width: NotchConstants.badgeCoinDiameter, height: NotchConstants.badgeCoinDiameter)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().fill(NotchTheme.panelBase.opacity(0.35)))
            )
            .overlay(Circle().stroke(NotchTheme.stroke, lineWidth: 0.75))
            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 0.5)
    }
}

private extension View {
    func coinBackground() -> some View { modifier(CoinBackground()) }
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
