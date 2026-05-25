import AppKit
import Foundation

/// Tracks AppleEvents (Automation) permission per-bundle for known media players.
///
/// **Probe policy** — the probe (`hasAutomationAccess`) issues a real AppleEvent,
/// which would surface a system permission dialog if the user has never been
/// prompted. To avoid cold-start dialog spam, we only probe bundles whose state
/// is already `.denied` — i.e. the user has already taken an action that
/// triggered the prompt and was rejected. Bundles stay `.unknown` until the
/// `MediaBridge.permissionDeniedCallback` push event flips them to `.denied`.
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
    }

    func stopProbing() {
        probeTimer?.invalidate()
        probeTimer = nil
    }

    /// Probe currently-denied bundles only. We deliberately do NOT probe
    /// `.unknown` or `.authorized` bundles: probing an unknown bundle would
    /// trigger the AppleEvents permission dialog without any user action;
    /// probing an authorized bundle is wasted I/O.
    private func probeAll() {
        for bundleID in monitoredBundles where states[bundleID] == .denied {
            guard MediaBridge.isRunning(bundleID: bundleID) else { continue }
            if MediaBridge.hasAutomationAccess(bundleID: bundleID) {
                recordAuthorized(bundleID: bundleID)
            }
        }
    }
}
