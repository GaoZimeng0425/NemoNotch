@testable import NemoNotch
import Testing

@Suite("NotchCapsule")
@MainActor
struct NotchCapsuleTests {
    private let charging = ChargingCapsuleEvent(percent: 87, isCharging: true, externalConnected: true)
    private let unplugged = ChargingCapsuleEvent(percent: 64, isCharging: false, externalConnected: false)
    private let headphones = BluetoothDeviceEvent(name: "AirPods Pro", isConnected: true)

    @Test("nothing to show without events")
    func empty() {
        #expect(NotchCapsule.current(charging: nil, bluetooth: nil) == nil)
    }

    @Test("charging wins over bluetooth and keeps its event id")
    func chargingWins() {
        let capsule = NotchCapsule.current(charging: charging, bluetooth: headphones)
        #expect(capsule?.id == charging.id)
        #expect(capsule?.icon == "bolt.fill")
        #expect(capsule?.text == charging.text)
    }

    @Test("unplugged shows the battery glyph")
    func unpluggedGlyph() {
        #expect(NotchCapsule.current(charging: unplugged, bluetooth: nil)?.icon == "battery.100")
    }

    @Test("bluetooth shows when no charging event")
    func bluetoothAlone() {
        let capsule = NotchCapsule.current(charging: nil, bluetooth: headphones)
        #expect(capsule?.id == headphones.id)
        #expect(capsule?.icon == "headphones")
        #expect(capsule?.text == headphones.text)
    }
}
