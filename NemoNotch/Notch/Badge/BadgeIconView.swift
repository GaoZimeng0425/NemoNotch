import SwiftUI

enum BadgeRenderStyle {
    case compactLeft
    case compactRight
    case row
}

// MARK: - BadgeIconView

struct BadgeIconView: View {
    let item: BadgeItem
    let style: BadgeRenderStyle
    let notificationService: NotificationService
    let mediaService: MediaService

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
        }
    }

    // MARK: - Notification

    @ViewBuilder
    private func notificationBadge(bundleID: String, count: Int) -> some View {
        switch style {
        case .compactLeft, .row:
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
                .modifier(PulseModifier(isActive: true))
        }
    }

    // MARK: - Media

    @ViewBuilder
    private var mediaBadge: some View {
        let isPlaying = mediaService.playbackState.isPlaying
        switch style {
        case .compactLeft, .row:
            VinylDiscView(
                isPlaying: isPlaying,
                artworkData: mediaService.playbackState.artworkData,
                appIcon: mediaService.appIcon,
                size: style == .row ? 18 : 20
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
                    .modifier(PulseModifier(isActive: true))
            } else {
                Circle()
                    .fill((source == .claude ? ToolStyle.color(tool) : Color.blue).opacity(0.7))
                    .frame(width: 8, height: 8)
            }
        case .row:
            aiSourceIcon(source: source, status: status)
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
        }
    }

    // MARK: - Agents

    @ViewBuilder
    private func agentsBadge(state: AgentMonitorState, emoji: String) -> some View {
        switch style {
        case .compactLeft, .row:
            if emoji.isEmpty {
                Image("HermesIcon")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: style == .row ? 14 : 13, height: style == .row ? 14 : 13)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            } else {
                Text(emoji)
                    .font(.system(size: style == .row ? 11 : 10))
            }
        case .compactRight:
            Image(systemName: state.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(agentMonitorStateColor(state))
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
        case .compactLeft, .row:
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NotchTheme.textPrimary)
        case .compactRight:
            Image(systemName: "clock.fill")
                .foregroundStyle(NotchTheme.textPrimary)
        }
    }
}

// MARK: - CompactBadgesView

struct CompactBadgesView: View {
    let items: [BadgeItem]
    let shownHasActiveBadge: Bool
    let notchLeftEdge: CGFloat
    let notchRightEdge: CGFloat
    let notchCenterY: CGFloat
    let onBadgeTap: (BadgeItem) -> Void
    let notificationService: NotificationService
    let mediaService: MediaService

    private var hasMultipleBadges: Bool {
        items.count >= 2
    }

    var body: some View {
        let spread: CGFloat = shownHasActiveBadge ? NotchConstants.badgeSpread : 0
        let primaryItem = items.first
        ZStack {
            if let item = primaryItem {
                Button {
                    onBadgeTap(item)
                } label: {
                    BadgeIconView(
                        item: item, style: .compactLeft,
                        notificationService: notificationService,
                        mediaService: mediaService
                    )
                }
                .buttonStyle(.plain)
                .position(x: notchLeftEdge - spread, y: notchCenterY)
                .opacity(shownHasActiveBadge ? 1 : 0)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: NotchConstants.badgeSpread)),
                    removal: .opacity.combined(with: .offset(x: NotchConstants.badgeSpread))
                ))
                Button {
                    onBadgeTap(item)
                } label: {
                    BadgeIconView(
                        item: item, style: .compactRight,
                        notificationService: notificationService,
                        mediaService: mediaService
                    )
                }
                .buttonStyle(.plain)
                .position(x: notchRightEdge + spread, y: notchCenterY)
                .opacity(shownHasActiveBadge ? 1 : 0)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: -NotchConstants.badgeSpread)),
                    removal: .opacity.combined(with: .offset(x: -NotchConstants.badgeSpread))
                ))
            }
        }
        .animation(
            .spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce),
            value: spread
        )
        .animation(
            .spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce),
            value: shownHasActiveBadge
        )
    }
}

// MARK: - BadgeRowView

struct BadgeRowView: View {
    let items: [BadgeItem]
    let notchCenterX: CGFloat
    let notchCenterY: CGFloat
    let onBadgeTap: (BadgeItem) -> Void
    let notificationService: NotificationService
    let mediaService: MediaService

    var body: some View {
        let secondaryBadges = Array(items.dropFirst())
        HStack(spacing: NotchConstants.badgeRowSpacing) {
            ForEach(secondaryBadges) { item in
                Button {
                    onBadgeTap(item)
                } label: {
                    BadgeIconView(
                        item: item, style: .row,
                        notificationService: notificationService,
                        mediaService: mediaService
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.8)),
            removal: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.8))
        ))
        .position(x: notchCenterX, y: notchCenterY)
    }
}
