import Foundation
@testable import NemoNotch
import SwiftUI
import Testing

/// Guards for the badge debounce (`applyBadgeUpdate`) — the logic that
/// absorbs momentary badge-set dips (e.g. an agent returning to `.idle`
/// between tool calls) so the collapsed notch doesn't replay its layout
/// animation.
///
/// On a virtual clock: the view model's scheduler is injected and the test
/// advances time by hand (these tests used to sleep real time and failed
/// whenever the host stalled for a few seconds). The checks are the old
/// wall-clock ones — held at +150ms, collapsed by +1000ms.
@MainActor
struct BadgeDebounceTests {
    private let media: [BadgeItem] = [.media]
    private let calendar: [BadgeItem] = [.calendar]

    /// A virtual clock: scheduled items run when `advance` passes their
    /// deadline, earliest first. A cancelled item is skipped by dispatch
    /// itself (`perform()` returns at once), as on the real queue.
    private final class VirtualClock {
        private(set) var now: TimeInterval = 0
        private var pending: [(deadline: TimeInterval, order: Int, item: DispatchWorkItem)] = []
        private var scheduled = 0

        var schedule: DelayScheduler {
            { [unowned self] delay, item in
                scheduled += 1
                pending.append((now + delay, scheduled, item))
            }
        }

        func advance(by seconds: TimeInterval) {
            now += seconds
            let due = pending.filter { $0.deadline <= now }.sorted { ($0.deadline, $0.order) < ($1.deadline, $1.order) }
            pending.removeAll { $0.deadline <= now }
            due.forEach { $0.item.perform() }
        }
    }

    private func makeViewModel(_ clock: VirtualClock) -> BadgeViewModel {
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
            appSettings: AppSettings(),
            schedule: clock.schedule
        )
        vm.initialize()
        return vm
    }

    /// The view model showing `items`, its update delivered.
    private func showing(_ items: [BadgeItem], _ clock: VirtualClock) -> BadgeViewModel {
        let vm = makeViewModel(clock)
        vm.applyBadgeUpdate(newTypes: items)
        clock.advance(by: 0.15)
        return vm
    }

    /// Coalesced, not synchronous — and landed well within 150ms.
    @Test func nonEmptyUpdateLandsAfterTheCoalesceTick() {
        let clock = VirtualClock()
        let vm = makeViewModel(clock)
        vm.applyBadgeUpdate(newTypes: media)
        #expect(vm.displayedBadgeItems != media)
        clock.advance(by: 0.15)
        #expect(vm.displayedBadgeItems == media)
        #expect(vm.shownHasActiveBadge)
    }

    /// The discriminating grace assertion: at +150ms (past the tick, inside
    /// the grace) the display must still show the OLD set. An implementation
    /// without the grace — or with one shrunk to the tick — collapses by then.
    @Test func emptyUpdateIsHeldDuringTheGraceWindow() {
        let clock = VirtualClock()
        let vm = showing(media, clock)
        vm.applyBadgeUpdate(newTypes: [])
        clock.advance(by: 0.15)
        #expect(vm.displayedBadgeItems == media)
        #expect(vm.shownHasActiveBadge)
    }

    /// A non-empty set inside the grace supersedes the pending collapse.
    @Test func nonEmptyWithinGraceCancelsTheCollapse() {
        let clock = VirtualClock()
        let vm = showing(media, clock)
        vm.applyBadgeUpdate(newTypes: [])
        clock.advance(by: 0.1)
        vm.applyBadgeUpdate(newTypes: calendar)
        clock.advance(by: 1.0) // past where the collapse would have landed
        #expect(vm.displayedBadgeItems == calendar)
        #expect(vm.shownHasActiveBadge)
    }

    @Test func emptyPastGraceCollapses() {
        let clock = VirtualClock()
        let vm = showing(media, clock)
        vm.applyBadgeUpdate(newTypes: [])
        clock.advance(by: 1.0)
        #expect(vm.displayedBadgeItems.isEmpty)
        #expect(!vm.shownHasActiveBadge)
    }
}
