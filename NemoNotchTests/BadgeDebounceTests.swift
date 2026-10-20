import Foundation
@testable import NemoNotch
import SwiftUI
import Testing

/// Guards for the badge debounce (`applyBadgeUpdate`) — the logic that
/// absorbs momentary badge-set dips (e.g. an agent returning to `.idle`
/// between tool calls) so the collapsed notch doesn't replay its layout
/// animation.
///
/// No wall clock: the view model's scheduler is injected and the test fires
/// the pending update by hand (these tests used to sleep real time and failed
/// whenever the host stalled for a few seconds).
@MainActor
struct BadgeDebounceTests {
    private let media: [BadgeItem] = [.media]
    private let calendar: [BadgeItem] = [.calendar]

    /// Collects scheduled updates; the test decides when they run.
    private final class ManualScheduler {
        var pending: [(delay: TimeInterval, item: DispatchWorkItem)] = []

        var schedule: DelayScheduler {
            { [unowned self] delay, item in pending.append((delay, item)) }
        }

        /// Runs everything scheduled so far in the order the clock would —
        /// shortest delay first, ties in scheduling order — stale items
        /// included, as a late dispatch would.
        func fireAll() {
            let due = pending.enumerated().sorted { ($0.element.delay, $0.offset) < ($1.element.delay, $1.offset) }
            pending = []
            due.forEach { $0.element.item.perform() }
        }
    }

    private func makeViewModel(_ scheduler: ManualScheduler) -> BadgeViewModel {
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
            schedule: scheduler.schedule
        )
        vm.initialize()
        return vm
    }

    /// The view model showing `items`, its update delivered.
    private func showing(_ items: [BadgeItem], _ scheduler: ManualScheduler) -> BadgeViewModel {
        let vm = makeViewModel(scheduler)
        vm.applyBadgeUpdate(newTypes: items)
        scheduler.fireAll()
        return vm
    }

    @Test func nonEmptyUpdateLandsOnTheCoalesceTick() {
        let scheduler = ManualScheduler()
        let vm = makeViewModel(scheduler)
        vm.applyBadgeUpdate(newTypes: media)
        #expect(scheduler.pending.map(\.delay) == [NotchConstants.badgeCoalesceTick])
        #expect(vm.displayedBadgeItems != media)
        scheduler.fireAll()
        #expect(vm.displayedBadgeItems == media)
        #expect(vm.shownHasActiveBadge)
    }

    /// The discriminating grace assertion: dropping to empty waits out the
    /// grace (not the tick), and until it runs the OLD set stays shown. An
    /// implementation without the grace collapses on the tick and fails here.
    @Test func emptyUpdateIsHeldForTheGrace() {
        let scheduler = ManualScheduler()
        let vm = showing(media, scheduler)
        vm.applyBadgeUpdate(newTypes: [])
        #expect(scheduler.pending.map(\.delay) == [NotchConstants.badgeEmptyGrace])
        #expect(vm.displayedBadgeItems == media)
        #expect(vm.shownHasActiveBadge)
    }

    /// A non-empty set inside the grace supersedes the pending collapse —
    /// even if the stale collapse is dispatched anyway, after it.
    @Test func nonEmptyWithinGraceCancelsTheCollapse() {
        let scheduler = ManualScheduler()
        let vm = showing(media, scheduler)
        vm.applyBadgeUpdate(newTypes: [])
        vm.applyBadgeUpdate(newTypes: calendar)
        scheduler.fireAll() // the calendar update on its tick, then the stale collapse
        #expect(vm.displayedBadgeItems == calendar)
        #expect(vm.shownHasActiveBadge)
    }

    @Test func emptyPastGraceCollapses() {
        let scheduler = ManualScheduler()
        let vm = showing(media, scheduler)
        vm.applyBadgeUpdate(newTypes: [])
        scheduler.fireAll()
        #expect(vm.displayedBadgeItems.isEmpty)
        #expect(!vm.shownHasActiveBadge)
    }
}
