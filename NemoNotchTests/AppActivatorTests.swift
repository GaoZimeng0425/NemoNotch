import AppKit
import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct AppActivatorTests {
    /// 1_234_567 is far above any allocatable pid (kern.pid_max tops out well
    /// below), so the walk is guaranteed to dead-end immediately.
    private static let bogusPID: Int32 = 1_234_567

    /// The walk's one step: a live process's parent. A CLI in a terminal is
    /// never a GUI app itself, so the host is only found by climbing — if
    /// this returns nil the session never gets Go-to-session.
    /// (A child we spawn, not this process: the test host is launched by
    /// launchd, ppid 1, which the walk deliberately treats as "no parent".)
    @Test func parentPIDOfAChildIsThisProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }
        #expect(AppActivator.parentPID(of: child.processIdentifier) == getpid())
    }

    @Test func hostAppPIDIsNilForDeadPID() {
        #expect(AppActivator.hostAppPID(of: Self.bogusPID) == nil)
    }

    @Test func hostAppPIDWalkTerminatesAtLaunchd() {
        // pid 1 is launchd — a GUI-app walk starting there must terminate
        // (launchd itself is not an NSRunningApplication).
        #expect(AppActivator.hostAppPID(of: 1) == nil)
    }

    @Test func recordHostKeepsPreviousHostOnTransientMiss() {
        var session = AISessionState(sessionId: "s1", source: .claude)
        session.launchingAppPID = 42
        session.launchingAppBundleId = "com.example.Terminal"

        AppActivator.recordHost(cliPID: Self.bogusPID, on: &session)

        #expect(session.launchingAppPID == 42)
        #expect(session.launchingAppBundleId == "com.example.Terminal")
    }

    @Test func recordHostLeavesEmptySessionUntouchedOnMiss() {
        var session = AISessionState(sessionId: "s1", source: .claude)

        AppActivator.recordHost(cliPID: Self.bogusPID, on: &session)

        #expect(session.launchingAppPID == nil)
        #expect(session.launchingAppBundleId == nil)
    }

    @Test func routedEventWithBogusPIDDoesNotDisturbSession() {
        // End-to-end routing wiring: an event carrying cli_pid flows through
        // routeEvent's recordHost path without disturbing the session (host
        // resolution legitimately finds nothing for a dead pid under the test
        // runner, so the session survives with no host recorded).
        let service = AICLIMonitorService()
        service.hookServer.onEventReceived?(
            HookEvent(
                hookEventName: "UserPromptSubmit",
                sessionId: "sess_appactivator_1",
                cliSource: "zcode",
                cliPID: Int(Self.bogusPID)
            )
        )
        let session = service.store.get("sess_appactivator_1")
        #expect(session != nil)
        #expect(session?.launchingAppPID == nil)
    }

    @Test("a zcode session resolves to the ZCode app, not its background helper")
    func skipsBackgroundHelper() {
        // Real tree, policies read live (2026-10-30): zcode-cli and
        // zcode-host-local-1 both report bundle dev.zcode.app.helper with
        // activationPolicy .accessory; only ZCode (dev.zcode.app) is .regular.
        let parents: [pid_t: pid_t] = [70919: 70909, 70909: 70848, 70848: 1]
        let policies: [pid_t: NSApplication.ActivationPolicy] = [70919: .accessory, 70909: .accessory, 70848: .regular]
        let host = AppActivator.hostAppPID(
            of: 70919,
            parent: { parents[$0] },
            policy: { policies[$0] }
        )
        #expect(host == 70848)
    }

    @Test("a terminal-hosted CLI still resolves to the terminal")
    func terminalHost() {
        // claude 500 → zsh 400 → login 300 → iTerm2 200 (.regular)
        let parents: [pid_t: pid_t] = [500: 400, 400: 300, 300: 200, 200: 1]
        let host = AppActivator.hostAppPID(
            of: 500,
            parent: { parents[$0] },
            policy: { $0 == 200 ? .regular : nil }
        )
        #expect(host == 200)
    }

    @Test("a terminal hiding its Dock icon (accessory) is still the host when nothing regular is above it")
    func accessoryTerminalFallback() {
        // claude 500 → zsh 400 → Ghostty 300 (.accessory, macos-hidden) → launchd
        let parents: [pid_t: pid_t] = [500: 400, 400: 300, 300: 1]
        let host = AppActivator.hostAppPID(
            of: 500,
            parent: { parents[$0] },
            policy: { $0 == 300 ? .accessory : nil },
            exclude: 999
        )
        #expect(host == 300)
    }

    @Test("a chat-bubble CLI whose only app ancestor is NemoNotch itself has no host")
    func ownProcessIsNeverTheHost() {
        // claude 500 → NemoNotch 24051 (.accessory, this process) → launchd
        let parents: [pid_t: pid_t] = [500: 24051, 24051: 1]
        let host = AppActivator.hostAppPID(
            of: 500,
            parent: { parents[$0] },
            policy: { $0 == 24051 ? .accessory : nil },
            exclude: 24051
        )
        #expect(host == nil)
    }
}
