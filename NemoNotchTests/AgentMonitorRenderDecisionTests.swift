@testable import NemoNotch
import Testing

@Suite("AgentMonitorRenderDecision")
struct AgentMonitorRenderDecisionTests {
    private func decide(
        hasOnlineMonitor: Bool = false,
        openClawPending: Bool = false,
        openClawInstalled: Bool = false,
        openClawEnabled: Bool = true,
        hermesInstalled: Bool = false,
        hermesEnabled: Bool = true
    ) -> AgentMonitorRenderDecision.Mode {
        AgentMonitorRenderDecision.decide(
            hasOnlineMonitor: hasOnlineMonitor,
            openClawPendingApproval: openClawPending,
            openClawIsInstalled: openClawInstalled,
            openClawUserEnabled: openClawEnabled,
            hermesIsInstalled: hermesInstalled,
            hermesUserEnabled: hermesEnabled
        )
    }

    @Test("Any monitor online → agentSections (no setup nag)")
    func anyMonitorOnline() {
        #expect(decide(hasOnlineMonitor: true) == .agentSections)
        #expect(decide(hasOnlineMonitor: true, openClawPending: true) == .agentSections)
        #expect(decide(hasOnlineMonitor: true, hermesInstalled: false) == .agentSections)
    }

    @Test("Nothing online, OpenClaw pending → approvalCardOnly")
    func openClawPendingTakesPriority() {
        #expect(decide(openClawPending: true, openClawInstalled: true) == .approvalCardOnly)
    }

    @Test("Nothing online, nothing installed → setupCards with both")
    func freshInstallShowsBothCards() {
        let mode = decide()
        #expect(mode == .setupCards(showHermesCard: true, openClaw: .installHintCard))
    }

    @Test("Nothing online, Hermes installed → offlineState (existing path)")
    func hermesInstalledFallsToOffline() {
        #expect(decide(hermesInstalled: true) == .offlineState)
    }

    @Test("Nothing online, OpenClaw installed (no pending) → offlineState")
    func openClawInstalledFallsToOffline() {
        #expect(decide(openClawInstalled: true) == .offlineState)
    }

    @Test("User disabled OpenClaw + nothing installed → setupCards without OpenClaw")
    func userDisabledHidesOpenClawCard() {
        let mode = decide(openClawEnabled: false)
        #expect(mode == .setupCards(showHermesCard: true, openClaw: .hidden))
    }

    @Test("User disabled OpenClaw + pending approval → still hidden (respects user choice)")
    func userDisabledOverridesPending() {
        // Edge case: user disabled OpenClaw while a stale pendingApproval lingers.
        // Honor the user's disable.
        let mode = decide(openClawPending: true, openClawEnabled: false)
        #expect(mode == .setupCards(showHermesCard: true, openClaw: .hidden))
    }

    @Test("User disabled Hermes + nothing installed → setupCards without Hermes card")
    func userDisabledHidesHermesCard() {
        let mode = decide(hermesEnabled: false)
        #expect(mode == .setupCards(showHermesCard: false, openClaw: .installHintCard))
    }

    @Test("User disabled both Hermes and OpenClaw → setupCards with neither card")
    func userDisabledBothHidesEverything() {
        let mode = decide(openClawEnabled: false, hermesEnabled: false)
        #expect(mode == .setupCards(showHermesCard: false, openClaw: .hidden))
    }
}
