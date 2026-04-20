import SwiftUI

struct NotchView: View {
    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self) var appSettings
    @Environment(MediaService.self) var mediaService
    @Environment(CalendarService.self) var calendarService
    @Environment(ClaudeCodeService.self) var claudeService
    @Environment(NotificationService.self) var notificationService
    @Environment(OpenClawService.self) var openClawService

    private var enabledTabs: Set<Tab> { appSettings.enabledTabs }

    private var screen: NSScreen { NSScreen.main! }
    private var hasNotch: Bool { screen.hasNotch }
    private var hardwareNotchSize: NSSize { coordinator.notchSize }

    private var notchCenterX: CGFloat { screen.frame.midX }
    private var notchLeftEdge: CGFloat { notchCenterX - hardwareNotchSize.width / 2 }
    private var notchRightEdge: CGFloat { notchCenterX + hardwareNotchSize.width / 2 }

    @State private var shownHasActiveBadge: Bool = false
    @State private var hideBadgeTask: Task<Void, Never>? = nil

    private var hasActiveBadge: Bool {
        if !notificationService.badges.isEmpty { return true }
        if mediaService.playbackState.isPlaying { return true }
        if claudeService.activeSession?.status == .working { return true }
        if openClawService.activeAgent != nil { return true }
        if let next = calendarService.nextEvent, !next.isPast {
            let minutes = Int(next.startDate.timeIntervalSinceNow / 60)
            if minutes >= 0, minutes < NotchConstants.upcomingEventThresholdMinutes { return true }
        }
        return false
    }

    private var notchSize: CGSize {
        switch coordinator.status {
        case .closed:
            let extraWidth: CGFloat = shownHasActiveBadge ? NotchConstants.badgePadding * 2 : 0
            return CGSize(width: hardwareNotchSize.width - NotchConstants.closedWidthInset + extraWidth, height: hardwareNotchSize.height)
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

            if coordinator.status == .closed {
                compactBadges
                    .zIndex(1)
                    .transition(.opacity)
            }

            if coordinator.status == .opened {
                openedContent
                    .zIndex(1)
                    .transition(.scale.combined(with: .opacity).combined(with: .offset(y: -NotchConstants.openTransitionOffset)))
                    .animation(.interactiveSpring(duration: NotchConstants.openSpringDuration).delay(NotchConstants.openContentDelay), value: coordinator.status)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

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

    private var openedContent: some View {
        VStack(spacing: 0) {
            TabBarView()
                .padding(.top, hardwareNotchSize.height + NotchConstants.tabBarTopPadding)

            tabContent
                .padding(.top, NotchConstants.tabContentTopPadding)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchConstants.tabContentHorizontalPadding)
        .frame(width: notchSize.width + notchCornerRadius * 2, height: notchSize.height)
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
        }
    }

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
        }
        .animation(.spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce), value: spread)
        .animation(.easeInOut(duration: NotchConstants.badgeFadeDuration), value: notificationService.badges.isEmpty)
    }
}
