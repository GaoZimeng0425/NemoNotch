import AppKit
import AudioToolbox
import CoreAudio
import CoreGraphics
import IOKit.ps
import SwiftUI

@Observable
final class HUDService {
    enum HUDType: Equatable {
        case volume
        case brightness
        case battery(charging: Bool)
    }

    var activeHUD: HUDType?
    var hudValue: Float = 0

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
    private var lastChargingState: Bool? = nil

    init() {
        LogService.info("HUDService init start", category: "HUD")
        setupVolumeListener()
        setupBrightnessMonitoring()
        setupBatteryMonitoring()
        LogService.info("HUDService init complete", category: "HUD")
    }

    deinit {
        brightnessTimer?.invalidate()
        if let handle = displayServicesHandle { dlclose(handle) }

        if let source = batteryRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        if let deviceID = volumeDeviceID, var address = volumeAddress, let listener = volumeListener {
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
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
        LogService.info("Volume diagnostic: status=\(diagStatus), value=\(diagVolume), device=\(deviceID)", category: "HUD")

        // Also listen for default device changes
        var devChangeAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devChangeAddr, DispatchQueue.main) { [weak self] _, _ in
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
            displayServicesHandle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_NOW)
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
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            let capacity = (info[kIOPSCurrentCapacityKey] as? Int) ?? 0
            let charging = info[kIOPSIsChargingKey] as? Bool ?? false

            let levelChanged = capacity != lastBatteryLevel
            let chargingChanged = charging != lastChargingState
            guard levelChanged || chargingChanged else { return }

            lastBatteryLevel = capacity
            lastChargingState = charging
            LogService.info("Battery changed: \(capacity)% charging=\(charging)", category: "HUD")

            // Only show HUD at 10% intervals
            if capacity % 10 == 0 || chargingChanged {
                showHUD(.battery(charging: charging), value: Float(capacity) / 100.0)
            }
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
