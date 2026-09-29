import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics
import IOKit.ps
import SwiftUI

/// One transient power-source event for the notch capsule. `id` is fresh per
/// event so a rapid plug→unplug reads as a new capsule, not an edit of the
/// showing one.
struct ChargingCapsuleEvent: Equatable {
    let id = UUID()
    let percent: Int
    let isCharging: Bool
    /// Adapter present — distinct from `isCharging`, which macOS drops when
    /// the battery is full while still plugged in; edges key on this.
    let externalConnected: Bool

    /// Capsule label, e.g. "正在充电 · 87%". Keys are format strings in the
    /// String Catalog (managed via scripts/xcstrings.py, not extracted).
    var text: String {
        let key: String
        if externalConnected {
            key = isCharging ? "charging.connected %d%%" : "charging.plugged %d%%"
        } else {
            key = "charging.disconnected %d%%"
        }
        return String(format: String(localized: String.LocalizationValue(key)), percent)
    }
}

@MainActor
@Observable
final class HUDService {
    enum HUDType: Equatable {
        case volume
        case brightness
        case battery(charging: Bool)
    }

    var activeHUD: HUDType?
    var hudValue: Float = 0

    /// Dynamic-Island-style charging capsule at the notch; nil = hidden.
    /// Owned here because the IOPS runloop subscription (below) already
    /// delivers the power-source edges that drive it.
    private(set) var chargingCapsule: ChargingCapsuleEvent?

    private let settings: AppSettings
    private var chargingCapsuleDismissTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var volumeAddress: AudioObjectPropertyAddress?
    private var volumeDeviceID: AudioObjectID?

    // Brightness
    private var brightnessTimer: Timer?
    private var lastBrightness: Float = -1
    private var displayServicesHandle: UnsafeMutableRawPointer?

    // Battery
    private var batteryRunLoopSource: CFRunLoopSource?
    private var lastBatteryLevel: Int = -1
    private var lastChargingState: Bool?
    private var lastExternalConnected: Bool?

    init(settings: AppSettings) {
        self.settings = settings
        LogService.info("HUDService init start", category: "HUD")
        setupVolumeListener()
        setupBrightnessMonitoring()
        setupBatteryMonitoring()
        LogService.info("HUDService init complete", category: "HUD")
    }

    deinit {
        MainActor.assumeIsolated {
            brightnessTimer?.invalidate()
            if let handle = displayServicesHandle { dlclose(handle) }
            chargingCapsuleDismissTask?.cancel()

            if let source = batteryRunLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            }

            if let deviceID = volumeDeviceID, var address = volumeAddress, let listener = volumeListener {
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
            }
        }
    }

    // MARK: - Volume

    private var defaultOutputDeviceID: AudioObjectID {
        var deviceID: AudioObjectID = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private func setupVolumeListener() {
        let deviceID = defaultOutputDeviceID
        guard deviceID != 0 else {
            LogService.warn("No default output device", category: "HUD")
            return
        }

        // Try VirtualMasterVolume first (works on most macOS 26 devices),
        // fall back to VolumeScalar for older devices
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if !AudioObjectHasProperty(deviceID, &address) {
            address.mSelector = kAudioDevicePropertyVolumeScalar
        }
        volumeAddress = address
        volumeDeviceID = deviceID

        volumeListener = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.readVolume()
            }
        }

        guard let listener = volumeListener else { return }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
        if status != noErr {
            LogService.warn("Failed to register volume listener: \(status)", category: "HUD")
        } else {
            LogService.info("Volume listener registered on device \(deviceID)", category: "HUD")
        }

        // Diagnostic: try reading volume directly
        var diagVolume: Float = 0
        var diagSize = UInt32(MemoryLayout<Float>.size)
        let diagStatus = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &diagSize, &diagVolume)
        LogService.info(
            "Volume diagnostic: status=\(diagStatus), value=\(diagVolume), device=\(deviceID)",
            category: "HUD"
        )

        // Also listen for default device changes
        var devChangeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devChangeAddr,
            DispatchQueue.main
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.rebindVolumeListener()
            }
        }
    }

    private func rebindVolumeListener() {
        if let oldID = volumeDeviceID, var addr = volumeAddress, let listener = volumeListener {
            AudioObjectRemovePropertyListenerBlock(oldID, &addr, DispatchQueue.main, listener)
        }
        setupVolumeListener()
    }

    private func readVolume() {
        let deviceID = volumeDeviceID ?? defaultOutputDeviceID
        guard deviceID != 0 else { return }
        var address = volumeAddress ?? AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return }

        LogService.info("Volume changed: \(volume)", category: "HUD")
        showHUD(.volume, value: volume)
    }

    // MARK: - Brightness

    private func setupBrightnessMonitoring() {
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.readBrightness()
            }
        }
        brightnessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func getBrightness() -> Float? {
        if displayServicesHandle == nil {
            displayServicesHandle = dlopen(
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                RTLD_LAZY | RTLD_NOW
            )
        }
        guard let handle = displayServicesHandle else {
            LogService.warn("Failed to load DisplayServices framework", category: "HUD")
            return nil
        }

        typealias GetBrightnessFunc = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        guard let sym = dlsym(handle, "DisplayServicesGetBrightness") else {
            LogService.warn("DisplayServicesGetBrightness symbol not found", category: "HUD")
            return nil
        }
        let funcPtr = unsafeBitCast(sym, to: GetBrightnessFunc.self)

        var brightness: Float = 0
        let result = funcPtr(CGMainDisplayID(), &brightness)
        guard result == 0 else {
            LogService.warn("DisplayServicesGetBrightness call failed (code: \(result))", category: "HUD")
            return nil
        }
        return brightness
    }

    private func readBrightness() {
        // 亮度轮询会在检测到变化时从 1s 提速到 0.1s，再自行回落。
        // 若长期停留在高频（看命中频率），说明回落逻辑没生效。
        let probe = PerfProbe.begin()
        defer { PerfProbe.end("HUDService.readBrightness", probe) }
        guard let brightness = getBrightness() else { return }

        if lastBrightness >= 0, abs(brightness - lastBrightness) > 0.01 {
            LogService.info("Brightness changed: \(brightness)", category: "HUD")
            showHUD(.brightness, value: brightness)
            // Speed up polling while brightness is changing
            brightnessTimer?.invalidate()
            let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.readBrightness()
                }
            }
            brightnessTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if lastBrightness >= 0 {
            // No change — slow back down
            if let timer = brightnessTimer, timer.timeInterval < 1.0 {
                timer.invalidate()
                let slowTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.readBrightness()
                    }
                }
                brightnessTimer = slowTimer
                RunLoop.main.add(slowTimer, forMode: .common)
            }
        }

        lastBrightness = brightness
    }

    // MARK: - Battery

    private func setupBatteryMonitoring() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let unmanagedSource = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                let service = Unmanaged<HUDService>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async {
                    service.readBattery()
                }
            },
            context
        ) else { return }

        let source = unmanagedSource.takeRetainedValue() as CFRunLoopSource
        batteryRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func readBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeRetainedValue() as? [String: Any]
            else { continue }
            let capacity = (info[kIOPSCurrentCapacityKey] as? Int) ?? 0
            let charging = info[kIOPSIsChargingKey] as? Bool ?? false
            // "AC Power" state == adapter present. There is no public
            // "external connected" bool key — Power Source State is the
            // public signal for it (kIOPSExternalConnectedKey is private).
            let powerState = info[kIOPSPowerSourceStateKey] as? String
            let externalConnected = powerState.map { $0 == kIOPSACPowerValue } ?? charging

            // First reading only seeds the baseline: power being already
            // connected at launch is not a "change" (the old code seeded
            // `lastChargingState` as nil, so every cold launch popped the
            // battery HUD once for nothing).
            if lastExternalConnected == nil {
                lastBatteryLevel = capacity
                lastChargingState = charging
                lastExternalConnected = externalConnected
                return
            }

            let levelChanged = capacity != lastBatteryLevel
            let chargingChanged = charging != lastChargingState
            let powerEdge = externalConnected != lastExternalConnected
            guard levelChanged || chargingChanged || powerEdge else { return }

            lastBatteryLevel = capacity
            lastChargingState = charging
            lastExternalConnected = externalConnected
            LogService.info(
                "Battery changed: \(capacity)% charging=\(charging) external=\(externalConnected)",
                category: "HUD"
            )

            if powerEdge {
                showChargingCapsule(percent: capacity, isCharging: charging, externalConnected: externalConnected)
            }
            // 10%-milestone pills stay; power/charging edges pop the pill only
            // when the notch capsule is disabled (otherwise double prompts).
            if capacity % 10 == 0 || ((powerEdge || chargingChanged) && !settings.chargingCapsuleEnabled) {
                // Round to nearest 10 for consistent look
                let displayLevel = Int((Double(capacity) / 10.0).rounded()) * 10
                showHUD(.battery(charging: charging), value: Float(min(max(displayLevel, 0), 100)) / 100.0)
            }
        }
    }

    // MARK: - Charging capsule

    /// Hides the charging capsule immediately (no dwell remainder). Called by
    /// NotchView when the notch opens, so the expanding panel never fights
    /// the capsule.
    func hideChargingCapsule() {
        chargingCapsuleDismissTask?.cancel()
        guard chargingCapsule != nil else { return }
        chargingCapsule = nil
    }

    private func showChargingCapsule(percent: Int, isCharging: Bool, externalConnected: Bool) {
        guard settings.chargingCapsuleEnabled else { return }
        chargingCapsule = ChargingCapsuleEvent(
            percent: percent,
            isCharging: isCharging,
            externalConnected: externalConnected
        )
        chargingCapsuleDismissTask?.cancel()
        chargingCapsuleDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NotchConstants.notchCapsuleDwell))
            guard let self, !Task.isCancelled else { return }
            self.chargingCapsule = nil
        }
    }

    // MARK: - Common

    private func showHUD(_ type: HUDType, value: Float) {
        activeHUD = type
        hudValue = value
        restartDismissTimer()
    }

    private func restartDismissTimer() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(NotchConstants.hudDismissDelay))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: NotchConstants.hudDismissDuration)) {
                activeHUD = nil
            }
        }
    }
}
