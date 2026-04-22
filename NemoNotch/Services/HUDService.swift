import AppKit
import AudioToolbox
import CoreAudio
import IOKit.ps
import SwiftUI

@Observable
final class HUDService {
    enum HUDType: Equatable {
        case volume
        case battery(charging: Bool)
    }

    var activeHUD: HUDType?
    var hudValue: Float = 0

    private var dismissTask: Task<Void, Never>?
    private var volumeListener: AudioObjectPropertyListenerBlock?
    private var volumeAddress: AudioObjectPropertyAddress?
    private var volumeDeviceID: AudioObjectID?

    // Battery
    private var batteryRunLoopSource: CFRunLoopSource?

    init() {
        LogService.info("HUDService init start", category: "HUD")
        setupVolumeListener()
        setupBatteryMonitoring()
        LogService.info("HUDService init complete", category: "HUD")
    }

    deinit {
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

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
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
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
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
