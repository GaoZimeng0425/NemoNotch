@testable import NemoNotch
import SwiftUI
import Testing

/// End-to-end timing guards for the badge debounce (`applyBadgeUpdate`) —
/// the logic that absorbs momentary badge-set dips (e.g. an agent returning
/// to `.idle` between tool calls) so the collapsed notch doesn't replay its
/// layout animation.
///
/// Real clocks, generous margins: assertions run ~10× past the 16ms
/// coalesce tick and check the grace window from both sides (held at +150ms,
/// collapsed at +1000ms against the 600ms grace). These margins hold unless
/// the host stalls by hundreds of milliseconds mid-test.
@MainActor
struct BadgeDebounceTests {
    private let media: [BadgeItem] = [.media]
    private let calendar: [BadgeItem] = [.calendar]

    private func makeViewModel() -> BadgeViewModel {
        let vm = BadgeViewModel(
            mediaService: MediaService(disableLiveUpdates: true),
            calendarService: CalendarService(),
            aiService: AICLIMonitorService(),
            notificationService: NotificationService(),
            agentRegistry: AgentMonitorRegistry(),
            pomodoroService: PomodoroTimerService(
                taskStore: TaskStore(),
                historyStore: PomodoroHistoryStore(),
                appSettings: AppSettings(),
                permissionMonitor: nil
            ),
            appSettings: AppSettings()
        )
        vm.initialize()
        return vm
    }

    private func settle(_ ms: Double = 150) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    @Test func nonEmptyUpdateLandsAfterTheCoalesceTick() async {
        let vm = makeViewModel()
        vm.applyBadgeUpdate(newTypes: media)
        await settle()
        #expect(vm.displayedBadgeItems == media)
        #expect(vm.shownHasActiveBadge)
    }

    /// The discriminating grace assertion: at +150ms (past the 16ms tick,
    /// inside the 600ms grace) the display must still show the OLD set. An
    /// implementation without the grace collapses immediately and fails here.
    @Test func emptyUpdateIsHeldDuringTheGraceWindow() async {
        let vm = makeViewModel()
        vm.applyBadgeUpdate(newTypes: media)
        await settle()
        vm.applyBadgeUpdate(newTypes: [])
        await settle()
        #expect(vm.displayedBadgeItems == media)
        #expect(vm.shownHasActiveBadge)
    }

    @Test func nonEmptyWithinGraceCancelsTheCollapse() async {
        let vm = makeViewModel()
        vm.applyBadgeUpdate(newTypes: media)
        await settle()
        vm.applyBadgeUpdate(newTypes: [])
        await settle(100)
        vm.applyBadgeUpdate(newTypes: calendar)
        await settle()
        #expect(vm.displayedBadgeItems == calendar)
        #expect(vm.shownHasActiveBadge)
    }

    @Test func emptyPastGraceCollapses() async {
        let vm = makeViewModel()
        vm.applyBadgeUpdate(newTypes: media)
        await settle()
        vm.applyBadgeUpdate(newTypes: [])
        await settle(1000)
        #expect(vm.displayedBadgeItems.isEmpty)
        #expect(!vm.shownHasActiveBadge)
    }
}
