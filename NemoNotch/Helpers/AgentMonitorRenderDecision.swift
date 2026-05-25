import Foundation

/// Pure decision logic for what AgentMonitorTab should render.
///
/// Extracted from AgentMonitorTab so the visibility rules in
/// `docs/superpowers/specs/2026-05-25-unified-service-enablement-design.md`
/// can be tested without mocking SwiftUI environments or MultiAgentMonitor
/// existentials.
enum AgentMonitorRenderDecision {
    enum Mode: Equatable {
        /// At least one monitor is online — show the existing agent rows.
        case agentSections
        /// Monitors installed but all offline — show the existing offlineState.
        case offlineState
        /// OpenClaw has a pending approval; render only its approval card.
        case approvalCardOnly
        /// Nothing installed — show the new setup cards.
        case setupCards(showHermesCard: Bool, openClaw: OpenClawCardKind)
    }

    enum OpenClawCardKind: Equatable {
        case approvalCard
        case installHintCard
        /// User explicitly disabled OpenClaw via Settings — don't nag.
        case hidden
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

        if hermesIsInstalled || openClawIsInstalled {
            return .offlineState
        }

        // Fresh state: show setup cards.
        let openClawKind: OpenClawCardKind = if !openClawUserEnabled {
            .hidden
        } else if openClawPendingApproval {
            .approvalCard
        } else {
            .installHintCard
        }

        return .setupCards(showHermesCard: hermesUserEnabled, openClaw: openClawKind)
    }
}
