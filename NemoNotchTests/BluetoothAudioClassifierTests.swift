@testable import NemoNotch
import IOBluetooth
import Testing

@Suite("BluetoothAudioClassifier")
struct BluetoothAudioClassifierTests {
    @Test("headphones COD (major audio) matches")
    func headphonesMatch() {
        // Real-world headphone COD: major 0x04 (audio), minor 0x06 (headphones),
        // service class audio + rendering → 0x240404.
        #expect(BluetoothAudioClassifier.isAudioDevice(classOfDevice: 0x240404))
    }

    @Test("headset COD (major audio) matches")
    func headsetMatches() {
        // Major 0x04 (audio), minor 0x01 (headset).
        #expect(BluetoothAudioClassifier.isAudioDevice(classOfDevice: 0x240402))
    }

    @Test("keyboard COD (major peripheral) does not match")
    func keyboardDoesNotMatch() {
        // Apple Magic Keyboard-style COD: major 0x05 (peripheral) — these
        // reconnect on every sleep/wake and must never toast.
        #expect(!BluetoothAudioClassifier.isAudioDevice(classOfDevice: 0x002540))
    }

    @Test("mouse COD (major peripheral) does not match")
    func mouseDoesNotMatch() {
        #expect(!BluetoothAudioClassifier.isAudioDevice(classOfDevice: 0x002580))
    }

    @Test("laptop COD with audio service bit still does not match")
    func laptopDoesNotMatch() {
        // MacBook-style COD: major 0x01 (computer). Its service class contains
        // the audio bit (0x100) — laptops advertise speakers/mics — so the
        // service bit must not be part of the match.
        #expect(!BluetoothAudioClassifier.isAudioDevice(classOfDevice: 0x38010C))
    }

    @Test("phone COD (major phone) does not match")
    func phoneDoesNotMatch() {
        // iPhone-style COD: major 0x02 (phone), service includes audio/telephony.
        #expect(!BluetoothAudioClassifier.isAudioDevice(classOfDevice: 0x7A020C))
    }

    @Test("zero COD does not match")
    func zeroDoesNotMatch() {
        #expect(!BluetoothAudioClassifier.isAudioDevice(classOfDevice: 0))
    }
}
