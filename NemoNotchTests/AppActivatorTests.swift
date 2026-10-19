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
}
