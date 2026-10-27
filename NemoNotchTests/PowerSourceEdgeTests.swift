import IOKit.ps
@testable import NemoNotch
import Testing

@Suite("PowerSourceEdge")
struct PowerSourceEdgeTests {
    private func info(
        type: String = kIOPSInternalBatteryType,
        capacity: Int,
        charging: Bool,
        state: String?
    ) -> [String: Any] {
        var dict: [String: Any] = [
            kIOPSTypeKey: type,
            kIOPSCurrentCapacityKey: capacity,
            kIOPSIsChargingKey: charging,
        ]
        dict[kIOPSPowerSourceStateKey] = state
        return dict
    }

    @Test("AC Power state means connected even when full and not charging")
    func fullOnAdapter() {
        let reading = PowerSourceEdge.reading(from: info(capacity: 100, charging: false, state: kIOPSACPowerValue))
        #expect(reading == PowerSourceReading(capacity: 100, isCharging: false, externalConnected: true))
    }

    @Test("battery power state means disconnected")
    func onBattery() {
        let reading = PowerSourceEdge.reading(from: info(capacity: 57, charging: false, state: kIOPSBatteryPowerValue))
        #expect(reading.externalConnected == false)
        #expect(reading.capacity == 57)
    }

    @Test("missing power state falls back to the charging flag")
    func missingStateFallsBack() {
        let reading = PowerSourceEdge.reading(from: info(capacity: 40, charging: true, state: nil))
        #expect(reading.externalConnected == true)
    }

    @Test("first reading only seeds the baseline")
    func firstReadingIsNotNews() {
        let now = PowerSourceReading(capacity: 80, isCharging: true, externalConnected: true)
        #expect(PowerSourceEdge.change(from: nil, to: now) == nil)
    }

    @Test("identical reading is not a change")
    func identicalIsNotNews() {
        let now = PowerSourceReading(capacity: 80, isCharging: true, externalConnected: true)
        #expect(PowerSourceEdge.change(from: now, to: now) == nil)
    }

    @Test("unplugging is a power edge")
    func unplugEdge() {
        let before = PowerSourceReading(capacity: 80, isCharging: true, externalConnected: true)
        let after = PowerSourceReading(capacity: 80, isCharging: false, externalConnected: false)
        let change = PowerSourceEdge.change(from: before, to: after)
        #expect(change == PowerSourceChange(
            reading: after, levelChanged: false, chargingChanged: true, powerEdge: true
        ))
    }

    @Test("charging stopping at full while plugged is not a power edge")
    func fullStopsChargingNoEdge() {
        let before = PowerSourceReading(capacity: 99, isCharging: true, externalConnected: true)
        let after = PowerSourceReading(capacity: 100, isCharging: false, externalConnected: true)
        let change = PowerSourceEdge.change(from: before, to: after)
        #expect(change?.powerEdge == false)
        #expect(change?.levelChanged == true)
        #expect(change?.chargingChanged == true)
    }

    @Test("a UPS listed before the internal battery is ignored")
    func upsListedFirst() {
        let ups = info(type: kIOPSUPSType, capacity: 100, charging: false, state: kIOPSACPowerValue)
        let battery = info(capacity: 42, charging: false, state: kIOPSBatteryPowerValue)
        let reading = PowerSourceEdge.trackedReading(in: [ups, battery])
        #expect(reading == PowerSourceReading(capacity: 42, isCharging: false, externalConnected: false))
    }

    @Test("no internal battery (desktop with only a UPS) tracks nothing")
    func upsOnly() {
        let ups = info(type: kIOPSUPSType, capacity: 100, charging: false, state: kIOPSACPowerValue)
        #expect(PowerSourceEdge.trackedReading(in: [ups]) == nil)
    }
}
