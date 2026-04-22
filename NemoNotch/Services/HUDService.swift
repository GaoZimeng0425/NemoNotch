import AppKit
import AudioToolbox
import CoreAudio
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

    // Brightness polling
    private var brightnessPollTimer: Timer?
    private var lastBrightness: Float = 0
    fileprivate static let coreDisplayHandle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)

    // Battery
    private var batteryRunLoopSource: CFRunLoopSource?

    init() {
        setupVolumeListener()
        setupBrightnessPolling()
        setupBatteryMonitoring()
    }

    deinit {
        brightnessPollTimer?.invalidate()

        if let source = batteryRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        if var address = volumeAddress, let listener = volumeListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                listener
            )
        }
    }

    // MARK: - Volume

    private func setupVolumeListener() {
        let deviceID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        volumeAddress = address

        volumeListener = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.readVolume()
            }
        }

        guard let listener = volumeListener else { return }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
        if status != noErr {
            LogService.warn("Failed to register volume listener: \(status)", category: "HUD")
        }
    }

    private func readVolume() {
        let deviceID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else { return }

        showHUD(.volume, value: volume)
    }

    // MARK: - Brightness

    private func setupBrightnessPolling() {
        lastBrightness = currentSystemBrightness
        brightnessPollTimer = Timer.scheduledTimer(
            withTimeInterval: NotchConstants.hudBrightnessPollInterval,
            repeats: true
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.pollBrightness()
            }
        }
    }

    private var currentSystemBrightness: Float {
        guard let screen = NSScreen.main else { return lastBrightness }
        let screenID = screen.displayID
        guard screenID != 0 else { return lastBrightness }
        return CoreDisplay_GetBrightness(screenID)
    }

    private func pollBrightness() {
        let brightness = currentSystemBrightness
        guard abs(brightness - lastBrightness) > 0.01 else { return }
        lastBrightness = brightness
        showHUD(.brightness, value: brightness)
    }

    // MARK: - Battery

    private func setupBatteryMonitoring() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                let service = Unmanaged<HUDService>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async {
                    service.readBattery()
                }
            },
            context
        ).takeRetainedValue() as CFRunLoopSource

        batteryRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        readBattery()
    }

    private func readBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeRetainedValue() as? [String: Any] else { continue }
            let capacity = (info[kIOPSCurrentCapacityKey] as? Int) ?? 0
            let charging = info[kIOPSIsChargingKey] as? Bool ?? false
            showHUD(.battery(charging: charging), value: Float(capacity) / 100.0)
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

// MARK: - CoreDisplay private API

private func CoreDisplay_GetBrightness(_ displayID: UInt32) -> Float {
    typealias Fn = @convention(c) (UInt32) -> Float
    guard let handle = HUDService.coreDisplayHandle,
          let sym = dlsym(handle, "CoreDisplay_GetBrightness") else { return 0 }
    return unsafeBitCast(sym, to: Fn.self)(displayID)
}
