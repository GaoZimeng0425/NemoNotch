@testable import NemoNotch
import Testing

@Suite("MediaAutomationPermissionMonitor")
struct MediaAutomationPermissionMonitorTests {
    @Test("Initial state is .unknown for every monitored bundle")
    @MainActor
    func initialState() {
        let monitor = MediaAutomationPermissionMonitor(
            monitoredBundles: ["com.apple.Music", "com.spotify.client"]
        )
        #expect(monitor.state(for: "com.apple.Music") == .unknown)
        #expect(monitor.state(for: "com.spotify.client") == .unknown)
        #expect(monitor.state(for: "com.example.unknown") == .unknown)
    }

    @Test("recordDenied flips bundle state to .denied")
    @MainActor
    func recordDenied() {
        let monitor = MediaAutomationPermissionMonitor(monitoredBundles: ["com.apple.Music"])
        monitor.recordDenied(bundleID: "com.apple.Music")
        #expect(monitor.state(for: "com.apple.Music") == .denied)
    }

    @Test("recordAuthorized flips bundle state to .authorized")
    @MainActor
    func recordAuthorized() {
        let monitor = MediaAutomationPermissionMonitor(monitoredBundles: ["com.apple.Music"])
        monitor.recordDenied(bundleID: "com.apple.Music")
        monitor.recordAuthorized(bundleID: "com.apple.Music")
        #expect(monitor.state(for: "com.apple.Music") == .authorized)
    }

    @Test("hasAnyDenied reflects aggregate state")
    @MainActor
    func aggregate() {
        let monitor = MediaAutomationPermissionMonitor(
            monitoredBundles: ["com.apple.Music", "com.spotify.client"]
        )
        #expect(monitor.hasAnyDenied == false)
        monitor.recordDenied(bundleID: "com.spotify.client")
        #expect(monitor.hasAnyDenied == true)
        monitor.recordAuthorized(bundleID: "com.spotify.client")
        #expect(monitor.hasAnyDenied == false)
    }

    @Test("recordDenied ignores bundles not in monitoredBundles")
    @MainActor
    func ignoresUnmonitored() {
        let monitor = MediaAutomationPermissionMonitor(monitoredBundles: ["com.apple.Music"])
        monitor.recordDenied(bundleID: "com.unrelated.app")
        #expect(monitor.state(for: "com.unrelated.app") == .unknown)
        #expect(monitor.hasAnyDenied == false)
    }
}
