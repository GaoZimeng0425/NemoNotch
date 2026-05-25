import Foundation

/// Pure decision logic for what AgentMonitorTab should render.
///
/// Extracted from AgentMonitorTab so the visibility rules in
/// `docs/superpowers/specs/2026-05-25-service-recovery-cards-design.md`
/// can be tested without mocking SwiftUI environments or MultiAgentMonitor
/// existentials.
enum AgentMonitorRenderDecision {
    enum Mode: Equatable {
        /// At least one monitor is online — show the existing agent rows.
        case agentSections
        /// Monitors ready (enabled+installed) but all offline — show offlineState.
        case offlineState
        /// OpenClaw has a pending approval; render only its approval card.
        case approvalCardOnly
        /// Nothing ready — show recovery cards (install or reenable per service).
        case setupCards(hermes: HermesCardKind, openClaw: OpenClawCardKind)
    }

    /// Card kind for the Hermes slot inside `setupCards`.
    enum HermesCardKind: Equatable {
        /// User enabled but hook not installed — active install CTA.
        case installCard
        /// User disabled — passive re-enable CTA.
        case reenableCard
    }

    /// Card kind for the OpenClaw slot inside `setupCards`.
    enum OpenClawCardKind: Equatable {
        /// Approval pending — render the existing OpenClawApprovalCard.
        case approvalCard
        /// User enabled, not installed (npm package missing) — install hint.
        case installHintCard
        /// User disabled — passive re-enable CTA.
        case reenableCard
    }

    static func decide(
        hasOnlineMonitor: Bool,
        openClawPendingApproval: Bool,
        openClawIsInstalled: Bool,
        openClawUserEnabled: Bool,
        hermesIsInstalled: Bool,
        hermesUserEnabled: Bool
    ) -> Mode {
        if hasOnlineMonitor {
            return .agentSections
        }

        // OpenClaw pending approval is high-priority — but only if the user
        // hasn't explicitly disabled OpenClaw.
        if openClawPendingApproval, openClawUserEnabled {
            return .approvalCardOnly
        }

        // "No nag" rule: only suppress recovery cards if a service is truly
        // ready (enabled AND installed). A disabled-but-installed service is
        // not "ready" because its connect/reconnect is blocked by the flag.
        let hermesReady = hermesUserEnabled && hermesIsInstalled
        let openClawReady = openClawUserEnabled && openClawIsInstalled
        if hermesReady || openClawReady {
            return .offlineState
        }

        let hermesKind: HermesCardKind = hermesUserEnabled ? .installCard : .reenableCard
        let openClawKind: OpenClawCardKind = if !openClawUserEnabled {
            .reenableCard
        } else if openClawPendingApproval {
            .approvalCard
        } else {
            .installHintCard
        }

        return .setupCards(hermes: hermesKind, openClaw: openClawKind)
    }
}
