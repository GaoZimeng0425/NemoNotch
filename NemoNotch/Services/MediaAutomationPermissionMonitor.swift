import AppKit
import Foundation

/// Tracks AppleEvents (Automation) permission per-bundle for known media players.
/// Updates via two paths:
/// 1. Periodic probe (5 s) of `MediaBridge.hasAutomationAccess` for running players.
/// 2. Push notifications from `MediaBridge.permissionDeniedCallback` (delegate-driven).
@MainActor
@Observable
final class MediaAutomationPermissionMonitor {
    enum PermissionState: Equatable {
        case unknown
        case authorized
        case denied
    }

    private(set) var states: [String: PermissionState] = [:]

    private let monitoredBundles: [String]
    private var probeTimer: Timer?

    init(monitoredBundles: [String]) {
        self.monitoredBundles = monitoredBundles
        for bundle in monitoredBundles {
            states[bundle] = .unknown
        }
    }

    deinit {
        MainActor.assumeIsolated {
            probeTimer?.invalidate()
        }
    }

    func state(for bundleID: String) -> PermissionState {
        states[bundleID] ?? .unknown
    }

    var hasAnyDenied: Bool {
        states.values.contains(.denied)
    }

    func recordDenied(bundleID: String) {
        guard monitoredBundles.contains(bundleID) else { return }
        if states[bundleID] != .denied {
            LogService.warn(
                "AutomationPermissionMonitor: \(bundleID) -> denied",
                category: "Permission"
            )
            states[bundleID] = .denied
        }
    }

    func recordAuthorized(bundleID: String) {
        guard monitoredBundles.contains(bundleID) else { return }
        if states[bundleID] != .authorized {
            LogService.info(
                "AutomationPermissionMonitor: \(bundleID) -> authorized",
                category: "Permission"
            )
            states[bundleID] = .authorized
        }
    }

    func startProbing() {
        probeTimer?.invalidate()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.probeAll()
            }
        }
        probeAll()
    }

    func stopProbing() {
        probeTimer?.invalidate()
        probeTimer = nil
    }

    private func probeAll() {
        for bundleID in monitoredBundles {
            // Only probe running apps — probing a not-running app launches it.
            guard MediaBridge.isRunning(bundleID: bundleID) else {
                states[bundleID] = .unknown
                continue
            }
            if MediaBridge.hasAutomationAccess(bundleID: bundleID) {
                recordAuthorized(bundleID: bundleID)
            } else {
                recordDenied(bundleID: bundleID)
            }
        }
    }
}
