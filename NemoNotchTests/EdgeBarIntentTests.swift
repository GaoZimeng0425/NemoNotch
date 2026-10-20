import Foundation
@testable import NemoNotch
import Testing

/// Collects scheduled items so a test fires them by hand.
@MainActor
private final class ManualClock {
    var items: [(delay: TimeInterval, item: DispatchWorkItem)] = []

    var scheduler: EdgeBarScheduler {
        { [unowned self] delay, item in items.append((delay, item)) }
    }

    func fireAll() {
        let pending = items
        items = []
        pending.forEach { $0.item.perform() }
    }
}

@MainActor
@Suite("EdgeBarIntent")
struct EdgeBarIntentTests {
    @Test func opensOnlyAfterTheDelay() {
        let clock = ManualClock()
        let intent = EdgeBarHoverIntent(schedule: clock.scheduler)
        var changes: [Bool] = []
        intent.onChange = { changes.append($0) }

        intent.pointerEntered()
        #expect(!intent.isOpen)
        #expect(clock.items.first?.delay == EdgeBarMotion.openDelay)
        clock.fireAll()
        #expect(intent.isOpen)
        #expect(changes == [true])
    }

    @Test func movesDoNotPushTheOpeningOut() {
        let clock = ManualClock()
        let intent = EdgeBarHoverIntent(schedule: clock.scheduler)
        intent.pointerEntered()
        intent.pointerEntered()
        intent.pointerEntered()
        #expect(clock.items.count == 1)
    }

    @Test func aBrushThatLeavesNeverOpens() {
        let clock = ManualClock()
        let intent = EdgeBarHoverIntent(schedule: clock.scheduler)
        intent.pointerEntered()
        intent.pointerExited()
        // The stale open item fires anyway: the generation check drops it.
        clock.fireAll()
        #expect(!intent.isOpen)
    }

    @Test func comingBackInsideTheToleranceKeepsItOpen() {
        let clock = ManualClock()
        let intent = EdgeBarHoverIntent(schedule: clock.scheduler)
        intent.pointerEntered()
        clock.fireAll()
        intent.pointerExited()
        #expect(clock.items.first?.delay == EdgeBarMotion.closeTolerance)
        intent.pointerEntered()
        clock.fireAll()
        #expect(intent.isOpen)
    }

    @Test func closeNowClosesAndReportsOnce() {
        let clock = ManualClock()
        let intent = EdgeBarHoverIntent(schedule: clock.scheduler)
        var changes: [Bool] = []
        intent.onChange = { changes.append($0) }
        intent.pointerEntered()
        clock.fireAll()
        intent.closeNow()
        intent.closeNow()
        #expect(!intent.isOpen)
        #expect(changes == [true, false])
    }

    @Test func rowCardWaitsForTheDwellThenSwitchesSlower() {
        let clock = ManualClock()
        let rows = EdgeBarRowSwitch(schedule: clock.scheduler)
        var selected: [String] = []
        rows.onSelect = { selected.append($0) }

        rows.hover("a", selected: nil)
        #expect(clock.items.first?.delay == EdgeBarMotion.rowDwell)
        clock.fireAll()
        #expect(selected == ["a"])

        rows.hover("b", selected: "a")
        #expect(clock.items.first?.delay == EdgeBarMotion.rowSwitch)
        clock.fireAll()
        #expect(selected == ["a", "b"])
    }

    @Test func crossingRowsOnTheWayToTheCardMovesNothing() {
        let clock = ManualClock()
        let rows = EdgeBarRowSwitch(schedule: clock.scheduler)
        var selected: [String] = []
        rows.onSelect = { selected.append($0) }

        rows.hover("b", selected: "a")
        // Off the rows (onto the card) before the delay.
        rows.hover(nil, selected: "a")
        clock.fireAll()
        #expect(selected.isEmpty)
    }
}
