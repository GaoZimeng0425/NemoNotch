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
    /// Direction of the last tab change (set in `selectTab` before the switch)
    /// so the slide transition enters from the side you're heading toward.
    @State private var tabSlideForward = true

    /// 折叠时是否仍挂载 `contentPanel`。
    ///
    /// 原先 `contentPanel` 无条件挂载、仅靠 opacity/scale 隐藏，于是折叠状态下
    /// 整个 tab 树依然活跃 —— `OverviewTab` 的媒体卡片会持续响应
    /// `playbackPosition`（每 0.5s 一变，各自触发一段 0.25s 动画），只要有活跃
    /// 动画，SwiftUI 就每帧重新遍历整个 display list，而且每块屏幕一份。
    /// 实测占进程 CPU 的 55%、内存的 60%。
    ///
    /// 进出动画交给 `.transition`（见 body），SwiftUI 会等移除动画播完才真正
    /// 卸载，所以折叠观感与原先一致，也不需要手动延迟卸载。
    @State private var contentMounted = false

    /// Cursor is dwelling on this screen's collapsed notch (the coordinator is
    /// counting down to a hover-open). Grows the shape slightly as a "peek"
    /// affordance during the dwell.
    private var isClosedHovering: Bool {
        effectiveStatus == .closed && coordinator.hoverScreenID == screen.displayID
    }

    private var notchSize: CGSize {
        switch effectiveStatus {
        case .closed:
            return CGSize(
                width: hardwareNotchSize.width - NotchConstants.closedWidthInset + closedBadgeExtraWidth
                    + (isClosedHovering ? NotchConstants.closedHoverExtraWidth : 0),
                height: hardwareNotchSize.height
                    + (isClosedHovering ? NotchConstants.closedHoverExtraHeight : 0)
            )
        case .opened:
            return CGSize(width: coordinator.openedWidth, height: NotchConstants.openedHeight)
        }
    }

    /// Extra collapsed-shape width needed so the black notch fully contains the
    /// fanned compact badges. The fans extend outward from the notch edges by
    /// `badgeSpread + index * step` per group (`CompactBadgesView`), so the
    /// shape must grow with the group count — a fixed padding left multi-group
    /// fans overflowing the shape. Symmetric about center; covers the wider of
    /// the two wings. A single badge yields the historical +72pt.
    private var closedBadgeExtraWidth: CGFloat {
        guard let vm = badgeViewModel, vm.shownHasActiveBadge else { return 0 }
        let cluster = vm.badgeCluster
        let leftSlots = cluster.groups.count + (cluster.overflow > 0 ? 1 : 0)
        let rightSlots = cluster.groups.count
        let leftExtent = NotchConstants.badgeSpread
            + CGFloat(max(0, leftSlots - 1)) * NotchConstants.badgeStackStep
        let rightExtent = NotchConstants.badgeSpread
            + CGFloat(max(0, rightSlots - 1)) * NotchConstants.badgeStatusStep
        let halfExtension = max(leftExtent, rightExtent) + NotchConstants.badgeEdgeMargin
        return NotchConstants.closedWidthInset + 2 * halfExtension
    }

    private var notchTopCornerRadius: CGFloat {
        switch effectiveStatus {
        case .closed: NotchConstants.cornerRadiusTopClosed
        case .opened: NotchConstants.cornerRadiusTopOpened
        }
    }

    private var notchBottomCornerRadius: CGFloat {
        switch effectiveStatus {
        case .closed: NotchConstants.cornerRadiusBottomClosed
        case .opened: NotchConstants.cornerRadiusBottomOpened
        }
    }

    /// Open gets a lively spring with a hint of bounce; close runs fully
    /// damped so the collapse lands crisply without a terminal jiggle.
    private var notchStateAnimation: Animation {
        switch effectiveStatus {
        case .opened: .spring(duration: NotchConstants.openSpringDuration, bounce: 0.1)
        case .closed: .spring(duration: NotchConstants.closeSpringDuration)
        }
    }

    var body: some View {
        let _ = PerfProbe.hit("NotchView.body")
        let shown = badgeViewModel?.shownHasActiveBadge ?? false

        ZStack(alignment: .top) {
            notchShape(shown: shown)
                .animation(notchStateAnimation, value: effectiveStatus)
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
                    cluster: badgeViewModel?.badgeCluster ?? BadgeCluster(groups: [], overflow: 0),
                    shownHasActiveBadge: shown,
                    notchLeftEdge: notchLeftEdge,
                    notchRightEdge: notchRightEdge,
                    notchCenterY: hardwareNotchSize.height / 2,
                    onBadgeTap: handleBadgeTap,
                    notificationService: notificationService,
                    mediaService: mediaService,
                    pomodoroService: pomodoroService
                )
                // Pseudo-continuity with the expanding panel: on open the
                // badges scale up and fade (reading as "growing into the
                // content"), on close they condense back in. Anchored at the
                // notch so the growth radiates from where the panel comes from.
                .transition(
                    .scale(scale: 1.35, anchor: .top)
                        .combined(with: .opacity)
                )
                .zIndex(1)
            }

            // 折叠后卸载整棵 tab 树（见 contentMounted）。放大 + 渐显由
            // .transition 承担：新插入的视图不会对绑定 effectiveStatus 的
            // scaleEffect/opacity 做动画（没有上一个值可插值），只有 transition
            // 才描述得了进出过程。
            if contentMounted {
                contentPanel
                    .allowsHitTesting(effectiveStatus == .opened)
                    .animation(
                        .spring(
                            duration: NotchConstants.tabSwitchSpringDuration,
                            bounce: NotchConstants.tabSwitchSpringBounce
                        ),
                        value: coordinator.selectedTab
                    )
                    .transition(
                        .scale(scale: 0.2, anchor: .top).combined(with: .opacity)
                    )
                    .zIndex(1)
            }

            // Chin bar: single three-column row straddling the hardware notch.
            // Left = tabs, middle = clear notch-width spacer, right = actions.
            // The outer frame (openedWidth) constrains everything inside, so
            // content can never spill past the notch shell.
            NotchChinBar(
                tabs: enabledTabs,
                selected: coordinator.selectedTab,
                openedWidth: coordinator.openedWidth,
                notchWidth: hardwareNotchSize.width,
                chinHeight: hardwareNotchSize.height,
                onSelect: selectTab,
                onClose: { coordinator.notchClose() }
            )
            .position(x: notchCenterX, y: hardwareNotchSize.height / 2)
            .opacity(effectiveStatus == .opened ? 1 : 0)
            .allowsHitTesting(effectiveStatus == .opened)
            .animation(notchStateAnimation, value: effectiveStatus)
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
        .onAppear {
            initializeBadgeViewModel()
            // 首帧按当前状态直接就位，不要动画。
            contentMounted = effectiveStatus != .closed
        }
        .onChange(of: effectiveStatus) { _, status in
            updateContentMount(for: status)
        }
        .onChange(of: badgeViewModel?.activeBadgeItems ?? []) { _, newTypes in
            badgeViewModel?.applyBadgeUpdate(newTypes: newTypes)
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

    /// 切换 contentPanel 的挂载。`withAnimation` 驱动 `.transition`，
    /// SwiftUI 负责在移除动画播完之后才卸载视图树。
    private func updateContentMount(for status: NotchCoordinator.Status) {
        let shouldMount = status != .closed
        guard shouldMount != contentMounted else { return }
        withAnimation(notchStateAnimation) {
            contentMounted = shouldMount
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
            bottomLeadingRadius: NotchConstants.cornerRadiusBottomOpened,
            bottomTrailingRadius: NotchConstants.cornerRadiusBottomOpened
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
        // Direction-aware slide-in, plain fade-out. Only the entering page
        // moves: a removal transition is captured at insertion time, so a
        // direction-dependent removal always exits with the PREVIOUS switch's
        // direction (visibly wrong on rapid back-and-forth switching). The
        // insertion reads fresh state, and its motion alone carries the
        // directional cue while spatial separation kills the ghosting.
        .transition(.asymmetric(
            insertion: .move(edge: tabSlideForward ? .trailing : .leading).combined(with: .opacity),
            removal: .opacity
        ))
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

    /// Activity glow for the expanded body. Only the opened, active screen
    /// glows; collapsed and non-active screens stay dark.
    private var notchGlow: NotchGlow {
        effectiveStatus == .closed ? .none : (badgeViewModel?.glowState ?? .none)
    }

    private func notchShape(shown: Bool) -> some View {
        NotchBackgroundView(
            status: effectiveStatus,
            notchSize: notchSize,
            topCornerRadius: notchTopCornerRadius,
            bottomCornerRadius: notchBottomCornerRadius,
            spacing: NotchConstants.notchBackgroundSpacing,
            glow: notchGlow
        )
        .animation(
            .spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce),
            value: shown
        )
        .animation(
            .spring(duration: NotchConstants.hoverPeekSpringDuration, bounce: 0.25),
            value: isClosedHovering
        )
        .animation(.easeInOut(duration: NotchConstants.fadeNormalDuration), value: notchGlow)
    }

    private func selectTab(_ tab: Tab) {
        guard tab != coordinator.selectedTab else { return }
        let tabs = enabledTabs
        if let from = tabs.firstIndex(of: coordinator.selectedTab),
           let to = tabs.firstIndex(of: tab) {
            tabSlideForward = to > from
        }
        coordinator.selectedTab = tab
    }
}
