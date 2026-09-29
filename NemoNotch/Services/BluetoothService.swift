import Foundation
import IOBluetooth

/// Classifies a Bluetooth Class-of-Device (COD) as an audio device or not.
/// COD layout: bits 23–13 service class, bits 12–8 major device class,
/// bits 7–2 minor. Headphones/headsets/speakers are always major = 0x04
/// (kBluetoothDeviceClassMajorAudio). The audio service-class bit (0x100) is
/// deliberately NOT consulted: laptops and phones also advertise it (they
/// have speakers/mics), which would misclassify a paired Mac/iPhone.
/// Keyboards/mice are major 0x05 (peripheral) and must not match — they
/// reconnect on every sleep/wake. Pure UInt32 math, unit-tested.
enum BluetoothAudioClassifier {
    static func isAudioDevice(classOfDevice cod: BluetoothClassOfDevice) -> Bool {
        (cod >> 8) & 0x1F == 0x04
    }
}

/// One transient audio-device event for the notch capsule. `id` is fresh per
/// event so a rapid connect→disconnect reads as a new capsule, not an edit of
/// the showing one.
struct BluetoothDeviceEvent: Equatable {
    let id = UUID()
    let name: String
    let isConnected: Bool
}

/// Monitors Bluetooth audio device (headphone/speaker) connections and shows
/// a Dynamic-Island-style capsule at the notch: the collapsed notch's black
/// shape springs open to reveal a headphone glyph + device name, dwells a
/// couple of seconds, and springs closed (`BluetoothCapsuleView`, mounted by
/// `NotchView` while collapsed).
///
/// Classic Bluetooth via the public IOBluetooth framework — AirPods and BT
/// headphones qualify; BLE-only peripherals are not covered (that would need
/// CoreBluetooth, with a different permission story). macOS 26 requires
/// `NSBluetoothAlwaysUsageDescription` (set in pbxproj) and raises the
/// Bluetooth TCC prompt on first use — the reason `start()` is skipped under
/// `UITestMode.isTestHost`. IOBluetooth user notifications are delivered on
/// the runloop that registered them; we register from the main actor, so the
/// @objc callbacks arrive on the main thread.
@MainActor
@Observable
final class BluetoothService: NSObject {
    private let settings: AppSettings

    private var started = false
    private var connectToken: IOBluetoothUserNotification?
    /// Per-device disconnect watchers keyed by Bluetooth address, registered
    /// on connect (and seeded at start for already-connected devices) and
    /// dropped when the device disconnects.
    private var disconnectTokens: [String: IOBluetoothUserNotification] = [:]

    /// Latest audio-device event to show as the notch capsule; nil = hidden.
    /// A new event overwrites the showing one and restarts the dwell.
    private(set) var capsuleEvent: BluetoothDeviceEvent?
    private var capsuleDismissTask: Task<Void, Never>?

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        LogService.info("BluetoothService init", category: "BluetoothService")
    }

    deinit {
        MainActor.assumeIsolated {
            connectToken?.unregister()
            for token in disconnectTokens.values {
                token.unregister()
            }
            capsuleDismissTask?.cancel()
            LogService.info("BluetoothService deinit", category: "BluetoothService")
        }
    }

    func start() {
        guard !started else { return }
        started = true
        connectToken = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceDidConnect(_:device:))
        )
        // Devices already connected at launch get disconnect watchers but no
        // capsule — that connection isn't news.
        for case let device as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] {
            guard device.isConnected(), isAudio(device) else { continue }
            watchDisconnect(device)
        }
        if connectToken == nil {
            LogService.warn("Bluetooth connect notification registration failed", category: "BluetoothService")
        } else {
            LogService.info(
                "Bluetooth monitoring started (\(disconnectTokens.count) audio device(s) already connected)",
                category: "BluetoothService"
            )
        }
    }

    // MARK: - Capsule lifecycle

    /// Hides the capsule immediately (no dwell remainder). Called by NotchView
    /// when the notch opens, so the expanding panel never fights the capsule.
    func hideCapsule() {
        capsuleDismissTask?.cancel()
        guard capsuleEvent != nil else { return }
        capsuleEvent = nil
    }

    private func showCapsule(name: String, isConnected: Bool) {
        guard settings.bluetoothToastEnabled else { return }
        capsuleEvent = BluetoothDeviceEvent(name: name, isConnected: isConnected)
        capsuleDismissTask?.cancel()
        capsuleDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NotchConstants.bluetoothCapsuleDwell))
            guard let self, !Task.isCancelled else { return }
            self.capsuleEvent = nil
        }
    }

    // MARK: - IOBluetooth callbacks
    //
    // Kept MainActor-isolated (not `nonisolated` + hop): IOBluetooth delivers
    // user notifications on the runloop that registered them — the main
    // runloop, since `start()` runs on the main actor — so the @objc dispatch
    // lands on the main thread and the isolation assert holds. Passing the
    // non-Sendable `IOBluetoothDevice` across a `nonisolated` boundary instead
    // would be rejected by the compiler as a data-race risk.

    @objc private func deviceDidConnect(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        guard isAudio(device) else {
            LogService.debug(
                "Bluetooth connect ignored (non-audio): \(device.nameOrAddress ?? "?")",
                category: "BluetoothService"
            )
            return
        }
        let name = device.nameOrAddress ?? "?"
        LogService.info("Bluetooth audio connected: \(name)", category: "BluetoothService")
        watchDisconnect(device)
        showCapsule(name: name, isConnected: true)
    }

    @objc private func deviceDidDisconnect(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        disconnectTokens.removeValue(forKey: device.addressString ?? "")
        let name = device.nameOrAddress ?? "?"
        LogService.info("Bluetooth audio disconnected: \(name)", category: "BluetoothService")
        showCapsule(name: name, isConnected: false)
    }

    // MARK: - Helpers

    private func isAudio(_ device: IOBluetoothDevice) -> Bool {
        BluetoothAudioClassifier.isAudioDevice(classOfDevice: device.classOfDevice)
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        guard let key = device.addressString, !key.isEmpty else { return }
        guard disconnectTokens[key] == nil else { return }
        disconnectTokens[key] = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDidDisconnect(_:device:))
        )
    }
}
