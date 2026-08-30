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
    @Environment(\.openSettings) private var openSettingsAction

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
    /// The page currently rendered — set from `coordinator.selectedTab`
    /// through `syncTabDisplay`, which wraps the change in the enter
    /// animation while the panel is open.
    @State private var displayedTab: Tab = .overview
    /// Blur flag, decoupled from the enter transition so the incoming page's
    /// blur can clear on its own (longer) schedule: snaps on with the swap,
    /// clears over `tabSwitchBlurClearDuration`.
    @State private var tabBlurOn = false

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

    /// Live size of the collapsed badge row, measured every layout pass while
    /// closed. This is what makes a single always-mounted shape possible: the
    /// collapsed width is content-driven (badge coins define it), the opened
    /// width is a constant, and `notchSize` needs both to come from one
    /// animatable value. Measuring both axes together also keeps them from
    /// desyncing — the badge row's own spring animates its frame, and the
    /// shape simply tracks the result 1:1, exactly as the old flexible
    /// `.background` did.
    @State private var closedContentSize: CGSize = .zero

    /// Collapsed shape size, floored at the physical notch so the first frame
    /// (before any measurement lands) and the empty-badge state still span the
    /// notch slot.
    private var closedNotchSize: CGSize {
        CGSize(
            width: max(closedContentSize.width, hardwareNotchSize.width),
            height: max(closedContentSize.height, hardwareNotchSize.height)
        )
    }

    private var notchSize: CGSize {
        switch effectiveStatus {
        case .closed:
            return closedNotchSize
        case .opened:
            return CGSize(width: coordinator.openedWidth, height: NotchConstants.openedHeight)
        }
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
            // ONE always-mounted shape for both states. It used to be branch-
            // swapped (collapsed shape as a `.background` vs. opened shape as
            // its own view), which changed view identity on open — SwiftUI can
            // only cross-fade across an identity change, so the black shape
            // never actually grew: the collapsed one ballooned out while a
            // full-size opened one faded in, and both were semi-transparent
            // mid-flight. Keeping one identity turns that into a real frame
            // animation (size + corner radii interpolate), with no cross-fade
            // and nothing translucent.
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

            // Badges ride on top of the shape rather than owning it. Still
            // conditionally mounted (they contain continuously-animating views
            // like VinylDiscView — see `contentMounted`), but their removal no
            // longer takes the shape with them.
            if effectiveStatus == .closed {
                collapsedBadges(shown: shown)
                    .zIndex(0.5)
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

            chinBar
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
            displayedTab = coordinator.selectedTab
        }
        .onChange(of: effectiveStatus) { _, status in
            updateContentMount(for: status)
        }
        .onChange(of: coordinator.selectedTab) { _, newTab in
            syncTabDisplay(to: newTab)
        }
        .onChange(of: badgeViewModel?.activeBadgeItems ?? []) { _, newTypes in
            badgeViewModel?.applyBadgeUpdate(newTypes: newTypes)
        }
        .onChange(of: aiService.activeSession?.phase.isWaitingForApproval == true) { _, _ in
            badgeViewModel?.checkApprovalSound(isOpen: effectiveStatus == .opened)
        }
        .animation(.spring(duration: NotchConstants.hudAppearDuration, bounce: 0.08), value: hudService.activeHUD)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.locale, appSettings.currentLocale)
        .contextMenu {
            // 走和齿轮按钮同一条路径:先开设置窗,再带 suppressAppRestore 收起刘海。
            // 直接用 SettingsLink 会让刘海留在 opened 状态,等用户下一次挪鼠标才
            // 关闭 —— 那一刻 restorePreviousApp() 会把右键前的前台 app 拉回来,
            // 刚打开的设置窗就被压到它后面(见 openSettings 的注释)。
            Button("notch.context.settings") {
                openSettings()
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

    // MARK: - Chin bar (extracted to keep body type-checkable)

    /// Three-column row straddling the hardware notch: tabs on the left,
    /// a clear notch-width spacer in the middle, actions on the right.
    /// The outer frame (openedWidth) constrains everything inside, so content
    /// can never spill past the notch shell.
    private var chinBar: some View {
        NotchChinBar(
            tabs: enabledTabs,
            selected: coordinator.selectedTab,
            openedWidth: coordinator.openedWidth,
            notchWidth: hardwareNotchSize.width,
            chinHeight: hardwareNotchSize.height,
            onSelect: selectTab,
            onSettings: openSettings,
            onQuit: { NSApp.terminate(nil) }
        )
        .position(x: notchCenterX, y: hardwareNotchSize.height / 2)
        .opacity(effectiveStatus == .opened ? 1 : 0)
        .allowsHitTesting(effectiveStatus == .opened)
        .animation(notchStateAnimation, value: effectiveStatus)
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
        let currentIndex = tabs.firstIndex(of: displayedTab) ?? 0

        return ZStack {
            Color.clear
                .contentShape(Rectangle())

            // NotchNook-style enter-only tab switch: the outgoing page gets
            // NO animation — the branch swap inside `withAnimation` replaces
            // it outright (`removal: .identity`) — while the incoming page
            // materializes out of the notch via `TabEnterTransition` (scaled
            // down toward its top edge, lifted, transparent, growing into
            // place). The blur is decoupled (`tabBlurOn`): it snaps on with
            // the swap and clears over the longer
            // `tabSwitchBlurClearDuration`, so the page arrives first and
            // sharpens afterwards.
            tabContent(for: displayedTab)
                .transition(.asymmetric(
                    insertion: .modifier(
                        active: TabEnterTransition(active: true),
                        identity: TabEnterTransition(active: false)
                    ),
                    removal: .identity
                ))
                .blur(radius: tabBlurOn ? NotchConstants.tabSwitchBlurRadius : 0)
        }
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
    private func tabContent(for tab: Tab) -> some View {
        switch tab {
        case .overview:
            OverviewTab()
        case .claude:
            AIAgentTabRoot()
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

    /// Collapsed badge row. Sizes to its coins + notch core (via `.fixedSize`),
    /// floored at the physical notch width so an empty state still spans the
    /// notch. Its measured size drives `closedNotchSize`, so the always-mounted
    /// shape behind it tracks this row exactly — the same effect the old
    /// flexible `.background` had, but without the shape being owned (and
    /// therefore unmounted) by this view.
    @ViewBuilder
    private func collapsedBadges(shown: Bool) -> some View {
        // The middle-column spacer spans the physical cutout exactly. It used
        // to be inset 4pt narrower, which left the shape smaller than the hole
        // it sits in — invisible at rest. Coins sit outside this core; the
        // shape widens to cover them when present.
        let notchCore = hardwareNotchSize.width
        return CompactBadgesView(
            cluster: badgeViewModel?.badgeCluster ?? BadgeCluster(groups: [], overflow: 0),
            shownHasActiveBadge: shown,
            notchMinWidth: notchCore,
            notchCoreWidth: notchCore,
            onBadgeTap: handleBadgeTap,
            notificationService: notificationService,
            mediaService: mediaService,
            pomodoroService: pomodoroService
        )
        .frame(height: hardwareNotchSize.height)
        .animation(
            .spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce),
            value: shown
        )
        // Feed the measured size to the shape. Assigned WITHOUT `withAnimation`
        // on purpose: this fires every layout pass, so during the badge/peek
        // springs above it reports each interpolated size and the shape simply
        // follows frame-by-frame. Wrapping it in its own animation would start
        // a second spring chasing the first — the desync that made the shape
        // look like a separate view from the badges.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard effectiveStatus == .closed, size.width > 0, size.height > 0 else { return }
            closedContentSize = size
        }
        // Pseudo-continuity with the expanding panel: on open the badges scale
        // up and fade (reading as "growing into the content"), on close they
        // condense back in. Anchored at the notch so the growth radiates from
        // where the panel comes from.
        .transition(
            .scale(scale: 1.35, anchor: .top)
                .combined(with: .opacity)
        )
    }

    private func notchShape(shown: Bool) -> some View {
        NotchBackgroundView(
            status: effectiveStatus,
            notchSize: notchSize,
            topCornerRadius: notchTopCornerRadius,
            bottomCornerRadius: notchBottomCornerRadius,
            spacing: NotchConstants.notchBackgroundSpacing,
            glow: notchGlow,
            // Always fixed now: the collapsed width used to come from flexing
            // to a parent badge row, but the shape has no such parent anymore —
            // it takes the measured width through `notchSize` instead, which is
            // what lets one view animate across both states.
            flexibleWidth: false
        )
        .animation(
            .spring(duration: NotchConstants.badgeSpringDuration, bounce: NotchConstants.badgeSpringBounce),
            value: shown
        )
        .animation(.easeInOut(duration: NotchConstants.fadeNormalDuration), value: notchGlow)
    }

    private func selectTab(_ tab: Tab) {
        guard tab != coordinator.selectedTab else { return }
        coordinator.selectedTab = tab
    }

    /// Every tab change funnels through `coordinator.selectedTab`, so this
    /// observer covers chin-bar clicks, the swipe gesture, per-tab hotkeys
    /// and `notchOpen(tab:)` alike. While the panel is open, the swap lands
    /// immediately inside the enter animation — the old page is replaced
    /// outright, nothing of it is kept. The blur snaps on with the swap and
    /// the one-frame task commits that on-state before clearing it over the
    /// slower `tabSwitchBlurClearDuration`. Otherwise (collapsed / not yet
    /// mounted) the rendered page snaps invisibly.
    private func syncTabDisplay(to tab: Tab) {
        guard tab != displayedTab else { return }
        guard contentMounted, effectiveStatus == .opened else {
            displayedTab = tab
            return
        }
        withAnimation(.spring(duration: NotchConstants.tabSwitchEnterDuration, bounce: NotchConstants.tabSwitchSpringBounce)) {
            displayedTab = tab
        }
        tabBlurOn = true
        Task { @MainActor in
            // One frame so the blurred first frame is committed before the
            // clear starts animating from it.
            try? await Task.sleep(for: .seconds(1.0 / 60.0))
            withAnimation(.easeOut(duration: NotchConstants.tabSwitchBlurClearDuration)) {
                tabBlurOn = false
            }
        }
    }

    /// Opens the Settings window and closes the notch without the 0.1s delay
    /// that caused perceived lag.
    ///
    /// Order matters: open Settings *first* so it's already frontmost when
    /// `notchClose`'s `restorePreviousApp()` runs. The coordinator's suppress
    /// flag ensures focus stays on Settings instead of bouncing to the
    /// previously-active app.
    private func openSettings() {
        openSettingsAction()
        coordinator.notchClose(suppressAppRestore: true)
    }
}

/// NotchNook-style entering tab page: materializes out of the notch — scaled
/// down toward its top edge, lifted, transparent — and grows into place. The
/// outgoing page is not animated at all; the branch swap replaces it
/// outright (`removal: .identity`). The enter blur is owned by `tabBlurOn`.
private struct TabEnterTransition: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(active ? NotchConstants.tabSwitchEnterScale : 1, anchor: .top)
            .offset(y: active ? -NotchConstants.tabSwitchEnterOffset : 0)
            .opacity(active ? 0 : 1)
    }
}
