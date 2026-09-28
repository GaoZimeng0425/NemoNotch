import Foundation
import IOBluetooth

/// Classifies a Bluetooth Class-of-Device (COD) as an audio device or not.
/// COD layout: bits 23–13 service class, bits 12–8 major device class,
/// bits 7–2 minor. Headphones/headsets/speakers are always major = 0x04
/// (kBluetoothDeviceClassMajorAudio). The audio service-class bit (0x100) is
/// deliberately NOT consulted: laptops and phones also advertise it (they
/// have speakers/mics), which would misclassify a paired Mac or iPhone.
/// Keyboards/mice are major 0x05 (peripheral) and must not match — they
/// reconnect on every sleep/wake. Pure UInt32 math, unit-tested.
enum BluetoothAudioClassifier {
    static func isAudioDevice(classOfDevice cod: BluetoothClassOfDevice) -> Bool {
        (cod >> 8) & 0x1F == 0x04
    }
}

/// Monitors Bluetooth audio device (headphone/speaker) connections and fires
/// the shared full-screen flash + toast on connect and disconnect.
///
/// Classic Bluetooth via the public IOBluetooth framework — AirPods and BT
/// headphones qualify; BLE-only peripherals are not covered (that would need
/// CoreBluetooth, with a different permission story). No TCC prompt, no
/// Info.plist key. IOBluetooth user notifications are delivered on the runloop
/// that registered them; we register from the main actor, so the @objc
/// callbacks arrive on the main thread and hop back via `assumeIsolated`.
@MainActor
@Observable
final class BluetoothService: NSObject {
    private let completionFlash: CompletionFlashService
    private let settings: AppSettings

    private var started = false
    private var connectToken: IOBluetoothUserNotification?
    /// Per-device disconnect watchers keyed by Bluetooth address, registered
    /// on connect (and seeded at start for already-connected devices) and
    /// dropped when the device disconnects.
    private var disconnectTokens: [String: IOBluetoothUserNotification] = [:]

    init(completionFlash: CompletionFlashService, settings: AppSettings) {
        self.completionFlash = completionFlash
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
        // toast — that connection isn't news.
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
        guard settings.bluetoothToastEnabled else { return }
        completionFlash.showCompletionFlash(items: [
            CompletionItem(
                name: String(format: String(localized: "bluetooth.connected %@"), name),
                source: .bluetooth
            )
        ])
    }

    @objc private func deviceDidDisconnect(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        disconnectTokens.removeValue(forKey: device.addressString ?? "")
        let name = device.nameOrAddress ?? "?"
        LogService.info("Bluetooth audio disconnected: \(name)", category: "BluetoothService")
        guard settings.bluetoothToastEnabled else { return }
        completionFlash.showCompletionFlash(items: [
            CompletionItem(
                name: String(format: String(localized: "bluetooth.disconnected %@"), name),
                source: .bluetooth
            )
        ])
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
