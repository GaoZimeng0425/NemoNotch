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

    /// Capsule label, e.g. "AirPods Pro 已连接". Keys are format strings in
    /// the String Catalog (managed via scripts/xcstrings.py, not extracted).
    var text: String {
        let key = isConnected ? "bluetooth.connected %@" : "bluetooth.disconnected %@"
        return String(format: String(localized: String.LocalizationValue(key)), name)
    }
}

/// Monitors Bluetooth audio device (headphone/speaker) connections and shows
/// a Dynamic-Island-style capsule at the notch: the collapsed notch's black
/// shape springs open to reveal a headphone glyph + device name, dwells a
/// couple of seconds, and springs closed (`NotchCapsuleView`, mounted by
/// `NotchView` while collapsed).
///
/// Classic Bluetooth via the public IOBluetooth framework — AirPods and BT
/// headphones qualify; BLE-only peripherals are not covered (that would need
/// CoreBluetooth, with a different permission story). macOS 26 requires
/// `NSBluetoothAlwaysUsageDescription` (set in pbxproj) and raises the
/// Bluetooth TCC prompt on first use — the reason `start()` is skipped under
/// `UITestMode.isTestHost`. IOBluetooth user notifications are NOT guaranteed
/// to arrive on the runloop that registered them (see the IOBluetooth callbacks
/// section below), so the @objc callbacks are `nonisolated` and hop to the
/// main actor.
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
        // IOBluetooth 的注册与已配对设备枚举都会同步初始化 CoreBluetooth 协调器,
        // macOS 27 上 bluetoothd 状态不佳时该初始化在信号量上**无限等待**
        // (2026-10-14 实测:主线程卡死在 applicationDidFinishLaunching,刘海不出现、
        // HookServer 饿死、所有 Task { @MainActor } 排不上队,整个 app 起不来)。
        // 因此这两步绝不能跑在主线程启动路径上 —— 挪到一条**带常驻 runloop 的专用
        // 线程**:经典蓝牙的连接通知按"注册线程的 runloop"投递,GCD 全局线程没有
        // runloop 会丢通知;BLE 可重连设备(AirPods 类)本就走协调器的内部队列,不受
        // 影响。协调器挂死时最多损失这一条线程,app 其余部分照常。@objc 回调是
        // nonisolated + Task hop(2026-10-12 修复),投递线程无关;IOBluetoothDevice
        // 非 Sendable 不能跨线程携带 —— 线程里只收集地址串,回主线程按址重查再挂
        // 断开监听。
        nonisolated(unsafe) let observer = self
        Thread.detachNewThread {
            let token = IOBluetoothDevice.register(
                forConnectNotifications: observer,
                selector: #selector(BluetoothService.deviceDidConnect(_:device:))
            )
            var connectedAudioAddresses: [String] = []
            for case let device as IOBluetoothDevice in IOBluetoothDevice.pairedDevices() ?? [] {
                guard device.isConnected(),
                      BluetoothAudioClassifier.isAudioDevice(classOfDevice: device.classOfDevice)
                else { continue }
                if let address = device.addressString, !address.isEmpty {
                    connectedAudioAddresses.append(address)
                }
            }
            DispatchQueue.main.async {
                observer.finishStartup(token: token, connectedAudioAddresses: connectedAudioAddresses)
            }
            // 常驻:经典蓝牙的连接通知要投递到本线程的 runloop。
            RunLoop.current.run()
        }
    }

    /// `start()` 的主线程收尾:落注册 token、为启动时已连接的音频设备挂断开监听。
    /// Devices already connected at launch get disconnect watchers but no
    /// capsule — that connection isn't news.
    private func finishStartup(token: IOBluetoothUserNotification?, connectedAudioAddresses: [String]) {
        connectToken = token
        for address in connectedAudioAddresses {
            if let device = IOBluetoothDevice(addressString: address) {
                watchDisconnect(device)
            }
        }
        if token == nil {
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
            try? await Task.sleep(for: .seconds(NotchConstants.notchCapsuleDwell))
            guard let self, !Task.isCancelled else { return }
            capsuleEvent = nil
        }
    }

    // MARK: - IOBluetooth callbacks

    //
    // These MUST be `nonisolated`: IOBluetooth does not reliably deliver user
    // notifications on the runloop that registered them. Connection events
    // routed through the CoreBluetooth coordinator (BLE-reconnectable devices
    // such as AirPods) arrive on IOBluetooth's internal
    // `com.apple.bluetooth.iobluetooth.coordinatorQueue` — measured as a
    // launch-time SIGTRAP in build 861 on macOS 27.0.1 (2026-10-12): a
    // @MainActor-isolated @objc callback tripped Swift 6's dispatch_assert_queue
    // isolation check ~1s after every launch while an AirPods reconnect
    // coincided, so the app "wouldn't open". Pattern: extract Sendable fields
    // (name / address / class-of-device) on the callback thread, then hop to
    // the main actor. The non-Sendable `IOBluetoothDevice` never crosses the
    // boundary — the main-actor side re-resolves it by address
    // (`IOBluetoothDevice(addressString:)`, the header's
    // +deviceWithAddressString:) when it needs the object for the
    // disconnect watcher.

    @objc private nonisolated func deviceDidConnect(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let name = device.nameOrAddress ?? "?"
        let address = device.addressString ?? ""
        guard BluetoothAudioClassifier.isAudioDevice(classOfDevice: device.classOfDevice) else {
            LogService.debug(
                "Bluetooth connect ignored (non-audio): \(name)",
                category: "BluetoothService"
            )
            return
        }
        LogService.info("Bluetooth audio connected: \(name)", category: "BluetoothService")
        Task { @MainActor [weak self] in
            self?.handleAudioConnect(name: name, address: address)
        }
    }

    @objc private nonisolated func deviceDidDisconnect(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let name = device.nameOrAddress ?? "?"
        let address = device.addressString ?? ""
        LogService.info("Bluetooth audio disconnected: \(name)", category: "BluetoothService")
        Task { @MainActor [weak self] in
            self?.handleAudioDisconnect(name: name, address: address)
        }
    }

    /// Main-actor side of the IOBluetooth callbacks above.
    private func handleAudioConnect(name: String, address: String) {
        if !address.isEmpty {
            // IOBluetoothDevice(addressString:) is the Swift import of the
            // header's +deviceWithAddressString: — lookup-or-create; for a
            // just-connected device this returns the live cached object.
            if let device = IOBluetoothDevice(addressString: address) {
                watchDisconnect(device)
            } else {
                LogService.warn(
                    "Bluetooth disconnect watcher skipped (device lookup failed): \(name)",
                    category: "BluetoothService"
                )
            }
        }
        showCapsule(name: name, isConnected: true)
    }

    private func handleAudioDisconnect(name: String, address: String) {
        disconnectTokens.removeValue(forKey: address)
        showCapsule(name: name, isConnected: false)
    }

    // MARK: - Helpers

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        guard let key = device.addressString, !key.isEmpty else { return }
        guard disconnectTokens[key] == nil else { return }
        disconnectTokens[key] = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDidDisconnect(_:device:))
        )
    }
}
