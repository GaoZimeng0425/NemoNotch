import Foundation
import CoreAudio
import AudioToolbox
import AppKit
import SwiftUI
import IOKit.ps

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

    // Brightness polling
    private var brightnessPollTimer: Timer?
    private var lastBrightness: Float = 0

    // Battery
    private var powerSourceNotifier: io_object_t = 0

    init() {
        setupVolumeListener()
        setupBrightnessPolling()
        setupBatteryMonitoring()
    }

    deinit {
        brightnessPollTimer?.invalidate()
    }

    // MARK: - Volume

    private func setupVolumeListener() {
        let deviceID = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        volumeListener = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.readVolume()
            }
        }

        guard let listener = volumeListener else { return }
        AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
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
        guard let screen = NSScreen.main else { return 0 }
        let screenID = screen.displayID
        if screenID != 0 {
            return CoreDisplay_GetBrightness(screenID)
        }
        return 0
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
        let loop = IOPSNotificationCreateRunLoopSource(
            { context in
                guard let context else { return }
                let service = Unmanaged<HUDService>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async {
                    service.readBattery()
                }
            },
            context
        ).takeRetainedValue() as CFRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), loop, .defaultMode)
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
    let sym = dlsym(dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY), "CoreDisplay_GetBrightness")
    guard let sym else { return 0 }
    return unsafeBitCast(sym, to: Fn.self)(displayID)
}

// MARK: - NSScreen displayID

extension NSScreen {
    var displayID: UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screenNumber = deviceDescription[key] as? NSNumber else { return 0 }
        return screenNumber.uint32Value
    }
}
