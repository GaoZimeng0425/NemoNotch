import SwiftUI

struct NotchView: View {
    let coordinator: NotchCoordinator
    let enabledTabs: Set<Tab>
    let mediaService: MediaService
    let calendarService: CalendarService
    let claudeService: ClaudeCodeService

    private var screen: NSScreen { NSScreen.main! }
    private var hasNotch: Bool { screen.hasNotch }
    private var hardwareNotchSize: NSSize { coordinator.notchSize }

    private var notchCenterX: CGFloat { screen.frame.midX }
    private var notchLeftEdge: CGFloat { notchCenterX - hardwareNotchSize.width / 2 }
    private var notchRightEdge: CGFloat { notchCenterX + hardwareNotchSize.width / 2 }

    private var notchSize: CGSize {
        switch coordinator.status {
        case .closed:
            CGSize(width: hardwareNotchSize.width - 4, height: hardwareNotchSize.height - 4)
        case .opened:
            CGSize(width: 500, height: 260)
        }
    }

    private var notchCornerRadius: CGFloat {
        switch coordinator.status {
        case .closed: 8
        case .opened: 24
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
                    .transition(.scale.combined(with: .opacity).combined(with: .offset(y: -130)))
                    .animation(.interactiveSpring(duration: 0.314).delay(0.157), value: coordinator.status)
            }
        }
        .animation(.interactiveSpring(duration: 0.314), value: coordinator.status)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    private var notchShape: some View {
        NotchBackgroundView(
            status: coordinator.status,
            notchSize: notchSize,
            hasNotch: hasNotch,
            cornerRadius: notchCornerRadius,
            spacing: 16
        )
    }

    private var openedContent: some View {
        VStack(spacing: 0) {
            TabBarView(coordinator: coordinator, enabledTabs: enabledTabs)
                .padding(.top, hardwareNotchSize.height + 10)

            tabContent
                .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(width: notchSize.width + notchCornerRadius * 2, height: notchSize.height)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch coordinator.selectedTab {
        case .media:
            MediaTab(mediaService: coordinator.mediaService)
        case .calendar:
            CalendarTab(calendarService: coordinator.calendarService)
        case .claude:
            ClaudeTab(claudeService: coordinator.claudeCodeService)
        case .launcher:
            LauncherTab(launcherService: coordinator.launcherService) {
                coordinator.notchClose()
            }
        }
    }

    private var sortedTabs: [Tab] {
        enabledTabs.sorted { Tab.allCases.firstIndex(of: $0)! < Tab.allCases.firstIndex(of: $1)! }
    }

    private var compactBadges: some View {
        let badge = CompactBadge(
            mediaService: mediaService,
            calendarService: calendarService,
            claudeService: claudeService,
            onTap: { tab in
                coordinator.notchOpen(tab: tab)
            }
        )
        return ZStack {
            badge.leftIcon
                .position(x: notchLeftEdge - 14, y: hardwareNotchSize.height / 2)
            badge.rightIcon
                .position(x: notchRightEdge + 14, y: hardwareNotchSize.height / 2)
        }
        .animation(.easeInOut(duration: 0.3), value: mediaService.playbackState.isPlaying)
        .animation(.easeInOut(duration: 0.3), value: claudeService.activeSession?.status == .working)
        .animation(.easeInOut(duration: 0.3), value: calendarService.nextEvent != nil)
    }
}
