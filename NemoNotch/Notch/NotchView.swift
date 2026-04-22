import SwiftUI

struct NotchView: View {
    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self) var appSettings
    @Environment(MediaService.self) var mediaService
    @Environment(CalendarService.self) var calendarService
    @Environment(ClaudeCodeService.self) var claudeService
    @Environment(NotificationService.self) var notificationService
    @Environment(OpenClawService.self) var openClawService
    @Environment(HUDService.self) var hudService

    private var enabledTabs: Set<Tab> { appSettings.enabledTabs }

    private var screen: NSScreen { NSScreen.main! }
    private var hasNotch: Bool { screen.hasNotch }
    private var hardwareNotchSize: NSSize { coordinator.notchSize }

    private var notchCenterX: CGFloat { screen.frame.midX }
    private var notchLeftEdge: CGFloat { notchCenterX - hardwareNotchSize.width / 2 }
    private var notchRightEdge: CGFloat { notchCenterX + hardwareNotchSize.width / 2 }

    @State private var shownHasActiveBadge: Bool = false
    @State private var hideBadgeTask: Task<Void, Never>? = nil
    @State private var displayedBadgeTypes: [BadgeType] = []
    @State private var badgeTypeUpdateTask: Task<Void, Never>? = nil
    @State private var dragOffset: CGFloat = 0
    @State private var slideForward: Bool = true

    private enum BadgeType: String, CaseIterable, Identifiable {
        case notification, media, claude, openclaw, calendar
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .notification: "bell.fill"
            case .media: "play.fill"
            case .claude: "cpu"
            case .openclaw: "terminal"
            case .calendar: "calendar"
            }
        }
        var tab: Tab {
            switch self {
            case .notification: .media
            case .media: .media
            case .claude: .claude
            case .openclaw: .openclaw
            case .calendar: .calendar
            }
        }
    }

    private var activeBadgeTypes: [BadgeType] {
        var types: [BadgeType] = []
        if !notificationService.badges.isEmpty { types.append(.notification) }
        if openClawService.activeAgent != nil { types.append(.openclaw) }
        if claudeService.activeSession?.status == .working { types.append(.claude) }
        if mediaService.playbackState.isPlaying { types.append(.media) }
        if let next = calendarService.nextEvent, !next.isPast {
            let minutes = Int(next.startDate.timeIntervalSinceNow / 60)
            if minutes >= 0, minutes < NotchConstants.upcomingEventThresholdMinutes { types.append(.calendar) }
        }
        return types
    }

    private var hasMultipleBadges: Bool { displayedBadgeTypes.count >= 2 }

    private var hasActiveBadge: Bool { !activeBadgeTypes.isEmpty }

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
        .animation(.interactiveSpring(duration: NotchConstants.openSpringDuration), value: coordinator.status)
        .onAppear { shownHasActiveBadge = hasActiveBadge }
        .onChange(of: hasActiveBadge) { _, newValue in
            if newValue {
                hideBadgeTask?.cancel()
                withAnimation(.spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce)) {
                    shownHasActiveBadge = true
                }
            } else {
                hideBadgeTask?.cancel()
                hideBadgeTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: NotchConstants.badgeFadeDuration)) {
                        shownHasActiveBadge = false
                    }
                }
            }
        }
        .onAppear { displayedBadgeTypes = activeBadgeTypes }
        .onChange(of: activeBadgeTypes) { oldTypes, newTypes in
            if newTypes.count > oldTypes.count {
                badgeTypeUpdateTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) {
                    displayedBadgeTypes = newTypes
                }
            } else {
                badgeTypeUpdateTask?.cancel()
                badgeTypeUpdateTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        displayedBadgeTypes = newTypes
                    }
                }
            }
        }
        .onChange(of: coordinator.selectedTab) { oldTab, newTab in
            let tabs = Tab.sorted(appSettings.enabledTabs)
            let oldIndex = tabs.firstIndex(of: oldTab) ?? 0
            let newIndex = tabs.firstIndex(of: newTab) ?? 0
            slideForward = newIndex > oldIndex
        }
        .animation(.spring(duration: NotchConstants.hudAppearDuration, bounce: 0.15), value: hudService.activeHUD)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    // MARK: - Tab icons in notch

    private var notchTabBar: some View {
        let tabs = Tab.sorted(appSettings.enabledTabs)
        let tabWidth: CGFloat = CGFloat(tabs.count) * 20 + CGFloat(tabs.count - 1) * 4
        return HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let selected = coordinator.selectedTab == tab
                Button {
                    coordinator.selectedTab = tab
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .white : .white.opacity(0.35))
                        .frame(width: 18, height: 18)
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
        .offset(x: dragOffset)
        .gesture(
            DragGesture(minimumDistance: 30)
                .onChanged { value in
                    let width = value.translation.width
                    let height = abs(value.translation.height)
                    guard height < abs(width) else { return }
                    dragOffset = width
                }
                .onEnded { value in
                    let threshold: CGFloat = 80
                    withAnimation(.interactiveSpring(duration: 0.3)) {
                        dragOffset = 0
                    }
                    if value.translation.width < -threshold && currentIndex + 1 < tabs.count {
                        slideForward = true
                        coordinator.selectNextTab()
                    } else if value.translation.width > threshold && currentIndex > 0 {
                        slideForward = false
                        coordinator.selectPreviousTab()
                    }
                }
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        switch coordinator.selectedTab {
        case .media:
            MediaTab()
        case .calendar:
            CalendarTab()
        case .claude:
            ClaudeTab()
        case .openclaw:
            OpenClawTab()
        case .launcher:
            LauncherTab {
                coordinator.notchClose()
            }
        case .weather:
            WeatherTab()
        case .system:
            EmptyView()
        }
    }

    // MARK: - Badge row (second row)

    private var badgeRow: some View {
        let secondaryBadges = Array(displayedBadgeTypes.dropFirst())
        return HStack(spacing: NotchConstants.badgeRowSpacing) {
            ForEach(secondaryBadges) { type in
                Button {
                    coordinator.notchOpen(tab: type.tab)
                } label: {
                    badgeRowIcon(for: type)
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

    @ViewBuilder
    private func badgeRowIcon(for type: BadgeType) -> some View {
        switch type {
        case .notification:
            if let top = notificationService.badges.values.max(by: { $0.count < $1.count }) {
                ZStack(alignment: .bottomTrailing) {
                    Image(nsImage: top.icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                    if top.count > 0 {
                        Text("\(top.count)")
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
        case .media:
            if let data = mediaService.playbackState.artworkData,
               let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .claude:
            ClaudeCrabIcon(size: 14)
        case .openclaw:
            Text("🦞")
                .font(.system(size: 11))
        case .calendar:
            Image(systemName: "calendar")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    // MARK: - Compact badges (left/right of notch)

    private var compactBadges: some View {
        let spread: CGFloat = shownHasActiveBadge ? NotchConstants.badgeSpread : 0
        return ZStack {
            CompactBadge(
                side: .left,
                onTap: { tab in
                    coordinator.notchOpen(tab: tab)
                },
                onOpenApp: { bundleID in
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        let config = NSWorkspace.OpenConfiguration()
                        NSWorkspace.shared.openApplication(at: url, configuration: config)
                    }
                }
            )
                .position(x: notchLeftEdge - spread, y: hardwareNotchSize.height / 2)
                .opacity(shownHasActiveBadge ? 1 : 0)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
            CompactBadge(
                side: .right,
                onTap: { tab in
                    coordinator.notchOpen(tab: tab)
                },
                onOpenApp: { bundleID in
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        let config = NSWorkspace.OpenConfiguration()
                        NSWorkspace.shared.openApplication(at: url, configuration: config)
                    }
                }
            )
                .position(x: notchRightEdge + spread, y: hardwareNotchSize.height / 2)
                .opacity(shownHasActiveBadge ? 1 : 0)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .leading)),
                    removal: .opacity.combined(with: .move(edge: .trailing))
                ))
        }
        .animation(.spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce), value: spread)
        .animation(.easeInOut(duration: NotchConstants.badgeFadeDuration), value: notificationService.badges.isEmpty)
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
}
