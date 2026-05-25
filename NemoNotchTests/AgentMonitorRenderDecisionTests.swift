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

    @Test("Nothing online, nothing installed → setupCards with both install kinds")
    func freshInstallShowsBothCards() {
        let mode = decide()
        #expect(mode == .setupCards(hermes: .installCard, openClaw: .installHintCard))
    }

    @Test("Nothing online, Hermes installed AND enabled → offlineState (no-nag: hermes ready)")
    func hermesInstalledAndEnabledFallsToOffline() {
        #expect(decide(hermesInstalled: true) == .offlineState)
    }

    @Test("Nothing online, OpenClaw installed AND enabled (no pending) → offlineState")
    func openClawInstalledAndEnabledFallsToOffline() {
        #expect(decide(openClawInstalled: true) == .offlineState)
    }

    @Test("User disabled OpenClaw + nothing installed → setupCards with openClaw reenable")
    func userDisabledOpenClawShowsReenable() {
        let mode = decide(openClawEnabled: false)
        #expect(mode == .setupCards(hermes: .installCard, openClaw: .reenableCard))
    }

    @Test("User disabled OpenClaw + pending approval → still reenable (respects user choice)")
    func userDisabledOverridesPending() {
        let mode = decide(openClawPending: true, openClawEnabled: false)
        #expect(mode == .setupCards(hermes: .installCard, openClaw: .reenableCard))
    }

    @Test("User disabled Hermes + nothing installed → setupCards with hermes reenable")
    func userDisabledHermesShowsReenable() {
        let mode = decide(hermesEnabled: false)
        #expect(mode == .setupCards(hermes: .reenableCard, openClaw: .installHintCard))
    }

    @Test("User disabled both Hermes and OpenClaw → setupCards with both reenable")
    func userDisabledBothShowsReenable() {
        let mode = decide(openClawEnabled: false, hermesEnabled: false)
        #expect(mode == .setupCards(hermes: .reenableCard, openClaw: .reenableCard))
    }

    @Test("User disabled OpenClaw + OpenClaw still installed → reenable (not stuck offline)")
    func disabledOpenClawWithOrphanInstallShowsReenable() {
        let mode = decide(openClawInstalled: true, openClawEnabled: false)
        #expect(mode == .setupCards(hermes: .installCard, openClaw: .reenableCard))
    }

    @Test("User disabled Hermes + Hermes still installed → reenable (not stuck offline)")
    func disabledHermesWithOrphanInstallShowsReenable() {
        let mode = decide(hermesInstalled: true, hermesEnabled: false)
        #expect(mode == .setupCards(hermes: .reenableCard, openClaw: .installHintCard))
    }
}
