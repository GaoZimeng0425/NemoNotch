import SwiftUI

struct NotchView: View {
    /// Screen this view instance renders on. Each `NotchWindowSlot` hosts its
    /// own NotchView bound to its display.
    let screen: NSScreen

    @Environment(NotchCoordinator.self) var coordinator
    @Environment(AppSettings.self) var appSettings
    @Environment(MediaService.self) var mediaService
    @Environment(AICLIMonitorService.self) var aiService
    @Environment(NotificationService.self) var notificationService
    @Environment(AgentMonitorRegistry.self) var agentRegistry
    @Environment(CalendarService.self) var calendarService
    @Environment(HUDService.self) var hudService
    @Environment(PomodoroTimerService.self) var pomodoroService

    private var hardwareNotchSize: NSSize {
        coordinator.notchSize
    }

    /// Horizontal center of this screen's hosting view in the view's LOCAL
    /// coordinate space (SwiftUI `.position` is local, not global). The hosting
    /// view is sized to `screen.frame.size` and offset within its window so
    /// that local-center aligns with the screen's physical notch — so the
    /// notch's local x is simply `width / 2`. Using global `screen.frame.midX`
    /// here only happens to work on the main screen at origin 0 and pushes
    /// every `.position`-anchored element offscreen on secondary displays.
    private var notchCenterX: CGFloat {
        screen.frame.width / 2
    }

    private var notchLeftEdge: CGFloat {
        notchCenterX - hardwareNotchSize.width / 2
    }

    private var notchRightEdge: CGFloat {
        notchCenterX + hardwareNotchSize.width / 2
    }

    /// Per-screen view of the coordinator's global status. Non-active screens
    /// always render the collapsed state so that only the mouse-targeted
    /// screen visually expands.
    private var effectiveStatus: NotchCoordinator.Status {
        coordinator.isActiveScreen(screen) ? coordinator.status : .closed
    }

    /// HUD shows on the built-in display when present (where keyboard
    /// system events originate), otherwise on the first connected screen.
    /// Either way, exactly one screen renders it.
    private var isHUDScreen: Bool {
        let target = NSScreen.screens.first(where: { $0.isBuiltInDisplay }) ?? NSScreen.screens.first
        return target?.displayID == screen.displayID
    }

    private var enabledTabs: [Tab] {
        Tab.sorted(appSettings.enabledTabs)
    }

    @State private var badgeViewModel: BadgeViewModel?
    @State private var dragOffset: CGFloat = 0

    private var notchSize: CGSize {
        switch effectiveStatus {
        case .closed:
            let hasBadge = badgeViewModel?.shownHasActiveBadge ?? false
            let multiBadges = badgeViewModel?.hasMultipleBadges ?? false
            let extraWidth: CGFloat = hasBadge ? NotchConstants.badgePadding * 2 : 0
            let extraHeight: CGFloat = (multiBadges && hasBadge) ? NotchConstants.badgeRowHeight : 0
            return CGSize(
                width: hardwareNotchSize.width - NotchConstants.closedWidthInset + extraWidth,
                height: hardwareNotchSize.height + extraHeight
            )
        case .opened:
            return CGSize(width: coordinator.openedWidth, height: NotchConstants.openedHeight)
        }
    }

    private var notchCornerRadius: CGFloat {
        switch effectiveStatus {
        case .closed: NotchConstants.cornerRadiusClosed
        case .opened: NotchConstants.cornerRadiusOpened
        }
    }

    var body: some View {
        let shown = badgeViewModel?.shownHasActiveBadge ?? false
        let items = badgeViewModel?.displayedBadgeItems ?? []

        ZStack(alignment: .top) {
            notchShape(shown: shown)
                .animation(.spring(duration: NotchConstants.openSpringDuration, bounce: 0.1), value: effectiveStatus)
                .animation(
                    .spring(
                        duration: NotchConstants.tabSwitchSpringDuration,
                        bounce: NotchConstants.tabSwitchSpringBounce
                    ),
                    value: coordinator.selectedTab
                )
                .zIndex(0)

            if effectiveStatus == .closed {
                CompactBadgesView(
                    items: items,
                    shownHasActiveBadge: shown,
                    notchLeftEdge: notchLeftEdge,
                    notchRightEdge: notchRightEdge,
                    notchCenterY: hardwareNotchSize.height / 2,
                    onBadgeTap: handleBadgeTap,
                    notificationService: notificationService,
                    mediaService: mediaService,
                    pomodoroService: pomodoroService
                )
                .zIndex(1)

                if badgeViewModel?.hasMultipleBadges == true {
                    BadgeRowView(
                        items: items,
                        notchCenterX: notchCenterX,
                        notchCenterY: hardwareNotchSize.height + NotchConstants.badgeRowHeight / 2,
                        onBadgeTap: handleBadgeTap,
                        notificationService: notificationService,
                        mediaService: mediaService,
                        pomodoroService: pomodoroService
                    )
                    .zIndex(1)
                    .opacity(shown ? 1 : 0)
                }
            }

            contentPanel
                .scaleEffect(effectiveStatus == .opened ? 1 : 0.2, anchor: .top)
                .opacity(effectiveStatus == .opened ? 1 : 0)
                .allowsHitTesting(effectiveStatus == .opened)
                .animation(
                    .spring(
                        duration: NotchConstants.tabSwitchSpringDuration,
                        bounce: NotchConstants.tabSwitchSpringBounce
                    ),
                    value: coordinator.selectedTab
                )
                .animation(.spring(duration: NotchConstants.openSpringDuration, bounce: 0.1), value: effectiveStatus)
                .zIndex(1)

            NotchTabBar(
                tabs: enabledTabs,
                selected: coordinator.selectedTab,
                trailingX: notchLeftEdge - 8,
                centerY: hardwareNotchSize.height / 2,
                onSelect: selectTab
            )
            .opacity(effectiveStatus == .opened ? 1 : 0)
            .allowsHitTesting(effectiveStatus == .opened)
            .animation(.spring(duration: NotchConstants.openSpringDuration, bounce: 0.1), value: effectiveStatus)
            .zIndex(2)

            // HUD overlay - render only on the primary HUD screen so it
            // doesn't flash on every connected display simultaneously.
            if isHUDScreen, let hudType = hudService.activeHUD {
                HUDOverlayView(type: hudType, value: hudService.hudValue)
                    .zIndex(3)
                    .position(
                        x: notchCenterX,
                        y: hardwareNotchSize.height + NotchConstants.hudTopPadding + NotchConstants.hudHeight / 2
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onAppear { initializeBadgeViewModel() }
        .onChange(of: badgeViewModel?.activeBadgeItems ?? []) { _, newTypes in
            badgeViewModel?.updateHasActiveBadge(!newTypes.isEmpty)
            badgeViewModel?.updateDisplayedBadges(newTypes: newTypes)
        }
        .onChange(of: aiService.activeSession?.phase.isWaitingForApproval == true) { _, _ in
            badgeViewModel?.checkApprovalSound(isOpen: effectiveStatus == .opened)
        }
        .animation(.spring(duration: NotchConstants.hudAppearDuration, bounce: 0.08), value: hudService.activeHUD)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
        .environment(\.locale, appSettings.currentLocale)
        .contextMenu {
            SettingsLink {
                Text("notch.context.settings")
            }
            Divider()
            Button("notch.context.quit") {
                NSApp.terminate(nil)
            }
        }
    }

    private func initializeBadgeViewModel() {
        guard badgeViewModel == nil else { return }
        let vm = BadgeViewModel(
            mediaService: mediaService,
            calendarService: calendarService,
            aiService: aiService,
            notificationService: notificationService,
            agentRegistry: agentRegistry,
            pomodoroService: pomodoroService,
            appSettings: appSettings
        )
        vm.initialize()
        badgeViewModel = vm
    }

    // MARK: - Badge interaction

    private func handleBadgeTap(_ item: BadgeItem) {
        switch item {
        case let .notification(bundleID, _):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        default:
            coordinator.notchOpen(tab: item.tab)
        }
    }

    // MARK: - Content panel (drops down from notch)

    private var contentPanel: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: hardwareNotchSize.height)

            swipeableContent
                .padding(NotchConstants.tabContentPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Spacer(minLength: 0)
        }
        .frame(width: coordinator.openedWidth, height: NotchConstants.openedHeight)
        .clipShape(.rect(
            bottomLeadingRadius: NotchConstants.cornerRadiusOpened,
            bottomTrailingRadius: NotchConstants.cornerRadiusOpened
        ))
    }

    // MARK: - Swipeable tab content

    private var swipeableContent: some View {
        let tabs = enabledTabs
        let currentIndex = tabs.firstIndex(of: coordinator.selectedTab) ?? 0

        return ZStack {
            Color.clear
                .contentShape(Rectangle())

            tabContent
        }
        .id(coordinator.selectedTab)
        .transition(.opacity)
        .animation(
            .spring(duration: NotchConstants.tabSwitchSpringDuration, bounce: NotchConstants.tabSwitchSpringBounce),
            value: coordinator.selectedTab
        )
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
                    withAnimation(.spring(
                        duration: NotchConstants.tabSwitchSpringDuration,
                        bounce: NotchConstants.tabSwitchSpringBounce
                    )) {
                        dragOffset = 0
                    }
                    if value.translation.width < -threshold, currentIndex + 1 < tabs.count {
                        selectTab(tabs[currentIndex + 1])
                    } else if value.translation.width > threshold, currentIndex > 0 {
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
        case .agents:
            AgentMonitorTab()
        case .launcher:
            LauncherTab {
                coordinator.notchClose()
            }
        case .pomodoro:
            PomodoroTab()
        case .system:
            SystemTab()
        }
    }

    // MARK: - Notch background shape

    private func notchShape(shown: Bool) -> some View {
        NotchBackgroundView(
            status: effectiveStatus,
            notchSize: notchSize,
            cornerRadius: notchCornerRadius,
            spacing: NotchConstants.notchBackgroundSpacing
        )
        .animation(
            .spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce),
            value: shown
        )
    }

    private func selectTab(_ tab: Tab) {
        guard tab != coordinator.selectedTab else { return }
        coordinator.selectedTab = tab
    }
}
