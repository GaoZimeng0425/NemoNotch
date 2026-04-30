import SwiftUI

struct NotchView: View {
    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self) var appSettings
    @Environment(MediaService.self) var mediaService
    @Environment(CalendarService.self) var calendarService
    @Environment(AICLIMonitorService.self) var aiService
    @Environment(NotificationService.self) var notificationService
    @Environment(OpenClawService.self) var openClawService
    @Environment(HUDService.self) var hudService

    private var enabledTabs: Set<Tab> { appSettings.enabledTabs }

    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }
    private var hasNotch: Bool { screen.hasNotch }
    private var hardwareNotchSize: NSSize { coordinator.notchSize }

    private var notchCenterX: CGFloat { screen.frame.midX }
    private var notchLeftEdge: CGFloat { notchCenterX - hardwareNotchSize.width / 2 }
    private var notchRightEdge: CGFloat { notchCenterX + hardwareNotchSize.width / 2 }

    @State private var shownHasActiveBadge: Bool = false
    @State private var displayedBadgeItems: [BadgeItem] = []
    @State private var badgeTypeUpdateTask: Task<Void, Never>? = nil
    @State private var dragOffset: CGFloat = 0
    @State private var slideForward: Bool = true
    @State private var previousSelectedTab: Tab? = nil
    @State private var wasWaitingForApproval = false

    private enum BadgeItem: Identifiable, Equatable {
        case notification(bundleID: String, count: Int)
        case media
        case ai(source: AISource, status: ClaudeStatus, tool: String?, waitingApproval: Bool, sessionID: String)
        case openclaw(state: AgentState, emoji: String)
        case calendar

        var id: String {
            switch self {
            case .notification(let bundleID, _): "notification:\(bundleID)"
            case .media: "media"
            case .ai(let source, let status, let tool, let waitingApproval, let sessionID):
                "ai:\(sessionID):\(source.rawValue):\(status):\(tool ?? "nil"):\(waitingApproval)"
            case .openclaw(let state, let emoji): "openclaw:\(state.rawValue):\(emoji)"
            case .calendar: "calendar"
            }
        }

        var tab: Tab {
            switch self {
            case .notification: .overview
            case .media: .overview
            case .ai: .claude
            case .openclaw: .openclaw
            case .calendar: .overview
            }
        }

        // Lower value = higher priority
        var priority: Int {
            switch self {
            case .ai(_, _, _, let waitingApproval, _) where waitingApproval:
                return 0
            case .notification:
                return 1
            case .openclaw:
                return 2
            case .ai:
                return 3
            case .media:
                return 4
            case .calendar:
                return 5
            }
        }
    }

    private var activeBadgeItems: [BadgeItem] {
        var items: [BadgeItem] = []
        
        // AI Sessions from both providers — all active sessions, not just the top one
        let allSessions = Array(aiService.claudeProvider.sessions.values) + Array(aiService.geminiProvider.sessions.values)
        let activeSessions = allSessions.filter { $0.phase.isActive || $0.phase.needsAttention }

        // Waiting for approval takes top priority
        for session in activeSessions {
            if session.phase.isWaitingForApproval {
                items.append(.ai(source: session.source, status: .waiting, tool: session.phase.approvalToolName, waitingApproval: true, sessionID: session.id))
            }
        }

        if let top = notificationService.badges.values.max(by: { $0.count < $1.count }) {
            items.append(.notification(bundleID: top.bundleID, count: top.count))
        }

        // OpenClaw — all non-idle agents
        for agent in openClawService.agents.values.filter({ $0.state != .idle }) {
            items.append(.openclaw(state: agent.state, emoji: agent.emoji))
        }

        // Working sessions
        for session in activeSessions {
            if !session.phase.isWaitingForApproval && session.status == ClaudeStatus.working {
                items.append(.ai(source: session.source, status: session.status, tool: session.currentTool, waitingApproval: false, sessionID: session.id))
            }
        }
        
        if mediaService.playbackState.isPlaying { items.append(.media) }
        if let next = calendarService.nextEvent, !next.isPast {
            let minutes = Int(next.startDate.timeIntervalSinceNow / 60)
            if minutes >= 0, minutes < NotchConstants.upcomingEventThresholdMinutes { items.append(.calendar) }
        }
        return items.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.id < rhs.id
        }
    }

    private var hasMultipleBadges: Bool { displayedBadgeItems.count >= 2 }

    private var hasActiveBadge: Bool { !activeBadgeItems.isEmpty }

    private var notchSize: CGSize {
        switch coordinator.status {
        case .closed:
            let extraWidth: CGFloat = shownHasActiveBadge ? NotchConstants.badgePadding * 2 : 0
            let extraHeight: CGFloat = (hasMultipleBadges && shownHasActiveBadge) ? NotchConstants.badgeRowHeight : 0
            return CGSize(width: hardwareNotchSize.width - NotchConstants.closedWidthInset + extraWidth,
                          height: hardwareNotchSize.height + extraHeight)
        case .opened:
            return CGSize(width: NotchConstants.openedWidth, height: NotchConstants.openedHeight)
        }
    }

    private var notchCornerRadius: CGFloat {
        switch coordinator.status {
        case .closed: NotchConstants.cornerRadiusClosed
        case .opened: NotchConstants.cornerRadiusOpened
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            notchShape
                .zIndex(0)

            if coordinator.status == .opened {
                notchTabBar
                    .zIndex(2)
                    .transition(.opacity)
            }

            if coordinator.status == .closed {
                compactBadges
                    .zIndex(1)

                if hasMultipleBadges {
                    badgeRow
                        .zIndex(1)
                        .opacity(shownHasActiveBadge ? 1 : 0)
                }
            }

            if coordinator.status == .opened {
                contentPanel
                    .zIndex(1)
            }

            // HUD overlay - appears below the notch
            if let hudType = hudService.activeHUD {
                HUDOverlayView(type: hudType, value: hudService.hudValue)
                    .zIndex(3)
                    .position(
                        x: notchCenterX,
                        y: hardwareNotchSize.height + NotchConstants.hudTopPadding + NotchConstants.hudHeight / 2
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear { shownHasActiveBadge = hasActiveBadge }
        .onAppear { previousSelectedTab = coordinator.selectedTab }
        .onAppear { wasWaitingForApproval = aiService.activeSession?.phase.isWaitingForApproval == true }
        .onChange(of: hasActiveBadge) { _, newValue in
            withAnimation(.spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce)) {
                shownHasActiveBadge = newValue
            }
        }
        .onAppear { displayedBadgeItems = activeBadgeItems }
        .onChange(of: activeBadgeItems) { _, newTypes in
            badgeTypeUpdateTask?.cancel()
            badgeTypeUpdateTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce)) {
                    displayedBadgeItems = newTypes
                }
            }
        }
        .onChange(of: aiService.activeSession?.phase.isWaitingForApproval == true) { _, isWaiting in
            if isWaiting && !wasWaitingForApproval && !TerminalDetector.isTerminalFrontmost && coordinator.status != .opened {
                NSSound(named: "Pop")?.play()
            }
            wasWaitingForApproval = isWaiting
        }
        .onChange(of: coordinator.selectedTab) { _, newTab in
            let tabs = Tab.sorted(appSettings.enabledTabs)
            if let previous = previousSelectedTab, previous != newTab {
                slideForward = tabIndex(of: newTab, in: tabs) > tabIndex(of: previous, in: tabs)
            }
            previousSelectedTab = newTab
        }
        .animation(.spring(duration: NotchConstants.hudAppearDuration, bounce: 0.08), value: hudService.activeHUD)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.locale, appSettings.currentLocale)
    }

    // MARK: - Tab icons in notch

    private var notchTabBar: some View {
        let tabs = Tab.sorted(appSettings.enabledTabs)
        let count = tabs.count
        let iconSize: CGFloat = count > 5 ? 16 : 18
        let spacing: CGFloat = count > 5 ? 3 : 4
        let fontSize: CGFloat = count > 5 ? 10 : 11
        let tabWidth: CGFloat = CGFloat(count) * iconSize + CGFloat(count - 1) * spacing
        return HStack(spacing: spacing) {
            ForEach(tabs) { tab in
                let selected = coordinator.selectedTab == tab
                Button {
                    selectTab(tab)
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: fontSize, weight: selected ? .semibold : .regular, design: .rounded))
                        .foregroundStyle(selected ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                        .frame(width: iconSize, height: iconSize)
                        .background(
                            RoundedRectangle(cornerRadius: iconSize / 3, style: .continuous)
                                .fill(selected ? NotchTheme.surfaceEmphasis : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .position(
            x: notchLeftEdge - tabWidth / 2 - 8,
            y: hardwareNotchSize.height / 2
        )
    }

    // MARK: - Content panel (drops down from notch)

    private var contentPanel: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: hardwareNotchSize.height)

            swipeableContent
                .padding(.horizontal, NotchConstants.tabContentHorizontalPadding)
                .padding(.top, NotchConstants.tabContentTopPadding)

            Spacer(minLength: 0)
        }
        .frame(width: notchSize.width, height: notchSize.height)
        .clipShape(.rect(
            bottomLeadingRadius: notchCornerRadius,
            bottomTrailingRadius: notchCornerRadius
        ))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Swipeable tab content

    private var swipeableContent: some View {
        let tabs = Tab.sorted(appSettings.enabledTabs)
        let currentIndex = tabs.firstIndex(of: coordinator.selectedTab) ?? 0

        return ZStack {
            Color.clear
                .contentShape(Rectangle())

            tabContent
        }
        .id(coordinator.selectedTab)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: slideForward ? .trailing : .leading)),
            removal: .opacity.combined(with: .move(edge: slideForward ? .leading : .trailing))
        ))
        .animation(.spring(duration: NotchConstants.tabSwitchSpringDuration, bounce: NotchConstants.tabSwitchSpringBounce), value: coordinator.selectedTab)
        .offset(x: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onChanged { value in
                    let width = value.translation.width
                    let height = abs(value.translation.height)
                    guard height < abs(width) else { return }
                    dragOffset = width * 0.38
                }
                .onEnded { value in
                    let threshold: CGFloat = 80
                    withAnimation(.spring(duration: NotchConstants.tabSwitchSpringDuration, bounce: NotchConstants.tabSwitchSpringBounce)) {
                        dragOffset = 0
                    }
                    if value.translation.width < -threshold && currentIndex + 1 < tabs.count {
                        selectTab(tabs[currentIndex + 1])
                    } else if value.translation.width > threshold && currentIndex > 0 {
                        selectTab(tabs[currentIndex - 1])
                    }
                }
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        switch coordinator.selectedTab {
        case .overview:
            OverviewTab()
        case .claude:
            AIChatTab()
        case .openclaw:
            OpenClawTab()
        case .launcher:
            LauncherTab {
                coordinator.notchClose()
            }
        case .system:
            SystemTab()
        }
    }

    // MARK: - Badge row (second row)

    private var badgeRow: some View {
        let secondaryBadges = Array(displayedBadgeItems.dropFirst())
        return HStack(spacing: NotchConstants.badgeRowSpacing) {
            ForEach(secondaryBadges) { item in
                Button {
                    handleBadgeTap(item)
                } label: {
                    badgeIcon(for: item, style: .row)
                }
                .buttonStyle(.plain)
            }
        }
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.8)),
            removal: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.8))
        ))
        .position(x: notchCenterX,
                  y: hardwareNotchSize.height + NotchConstants.badgeRowHeight / 2)
    }

    // MARK: - Compact badges (left/right of notch)

    private var compactBadges: some View {
        let spread: CGFloat = shownHasActiveBadge ? NotchConstants.badgeSpread : 0
        let primaryItem = displayedBadgeItems.first
        return ZStack {
            if let item = primaryItem {
                Button {
                    handleBadgeTap(item)
                } label: {
                    badgeIcon(for: item, style: .compactLeft)
                }
                .buttonStyle(.plain)
                .position(x: notchLeftEdge - spread, y: hardwareNotchSize.height / 2)
                .opacity(shownHasActiveBadge ? 1 : 0)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: NotchConstants.badgeSpread)),
                    removal: .opacity.combined(with: .offset(x: NotchConstants.badgeSpread))
                ))
                Button {
                    handleBadgeTap(item)
                } label: {
                    badgeIcon(for: item, style: .compactRight)
                }
                .buttonStyle(.plain)
                .position(x: notchRightEdge + spread, y: hardwareNotchSize.height / 2)
                .opacity(shownHasActiveBadge ? 1 : 0)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(x: -NotchConstants.badgeSpread)),
                    removal: .opacity.combined(with: .offset(x: -NotchConstants.badgeSpread))
                ))
            }
        }
        .animation(.spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce), value: spread)
        .animation(.spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce), value: shownHasActiveBadge)
    }

    // MARK: - Notch background shape

    private var notchShape: some View {
        NotchBackgroundView(
            status: coordinator.status,
            notchSize: notchSize,
            hasNotch: hasNotch,
            cornerRadius: notchCornerRadius,
            spacing: NotchConstants.notchBackgroundSpacing
        )
        .animation(.spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce), value: shownHasActiveBadge)
    }

    // MARK: - Badge rendering

    private enum BadgeRenderStyle {
        case compactLeft
        case compactRight
        case row
    }

    private func handleBadgeTap(_ item: BadgeItem) {
        switch item {
        case .notification(let bundleID, _):
            openApp(bundleID: bundleID)
        default:
            coordinator.notchOpen(tab: item.tab)
        }
    }

    private func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    @ViewBuilder
    private func badgeIcon(for item: BadgeItem, style: BadgeRenderStyle) -> some View {
        switch item {
        case .notification(let bundleID, let count):
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
        case .media:
            switch style {
            case .compactLeft, .row:
                if let data = mediaService.playbackState.artworkData,
                   let nsImage = NSImage(data: data) {
                    GeometryReader { geo in
                        let imgAspect = nsImage.size.width / max(nsImage.size.height, 1)
                        let viewAspect = geo.size.width / max(geo.size.height, 1)
                        let scale = imgAspect > viewAspect
                            ? geo.size.height / max(nsImage.size.height, 1)
                            : geo.size.width / max(nsImage.size.width, 1)
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(
                                width: nsImage.size.width * scale,
                                height: nsImage.size.height * scale
                            )
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                    .frame(width: 16, height: 16)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if let appIcon = mediaService.appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchTheme.textSecondary)
                }
            case .compactRight:
                Image(systemName: "play.fill")
                    .foregroundStyle(NotchTheme.textPrimary)
            }
        case .ai(let source, let status, let tool, let waitingApproval, _):
            switch style {
            case .compactLeft:
                switch source {
                case .claude:
                    ClaudeCrabIcon(size: 14, animateLegs: status == .working)
                case .gemini:
                    Image(systemName: "sparkle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                }
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
                switch source {
                case .claude:
                    ClaudeCrabIcon(size: 14, animateLegs: status == .working)
                case .gemini:
                    Image(systemName: "sparkle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
        case .openclaw(let state, let emoji):
            switch style {
            case .compactLeft, .row:
                Text(emoji)
                    .font(.system(size: style == .row ? 11 : 10))
            case .compactRight:
                Image(systemName: state.icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(openClawStateColor(state))
                    .modifier(PulseModifier(isActive: state == .working || state == .toolCalling))
            }
        case .calendar:
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

    private func openClawStateColor(_ state: AgentState) -> Color {
        switch state {
        case .idle:
            return NotchTheme.textSecondary
        case .working:
            return .blue
        case .speaking:
            return .green
        case .toolCalling:
            return NotchTheme.accent
        case .error:
            return .red
        }
    }

    // MARK: - Tab direction

    private func tabIndex(of tab: Tab, in tabs: [Tab]) -> Int {
        tabs.firstIndex(of: tab) ?? 0
    }

    private func selectTab(_ tab: Tab) {
        let tabs = Tab.sorted(appSettings.enabledTabs)
        guard tab != coordinator.selectedTab else { return }
        slideForward = tabIndex(of: tab, in: tabs) > tabIndex(of: coordinator.selectedTab, in: tabs)
        previousSelectedTab = coordinator.selectedTab
        coordinator.selectedTab = tab
    }
}
