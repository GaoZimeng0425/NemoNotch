import SwiftUI

extension AIChatTab {
    // MARK: - Empty state

    /// No-session content rendered inside the list's scroll area (the console
    /// header above stays mounted either way): the provider install/enable
    /// cards plus a run hint. The server status is not repeated here — the
    /// header's context card already shows it while there are no sessions.
    var setupList: some View {
        VStack(spacing: 12) {
            providerStatusList
            agentSetupCards
            if hasAnyReadyProvider {
                Text("ai.empty.run_hint")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.bottom, 10)
    }

    /// Agent-monitor setup cards (Hermes / OpenClaw) shown only when neither
    /// agent service is ready — the same "no nag" rule the standalone agents
    /// tab used (`AgentMonitorRenderDecision`): enabled+installed services
    /// show nothing here; their agents appear in the list once they run.
    @ViewBuilder
    var agentSetupCards: some View {
        let mode = AgentMonitorRenderDecision.decide(
            hasOnlineMonitor: agentRegistry.installedMonitors.contains(where: \.isOnline),
            openClawPendingApproval: openClaw.pendingApproval != nil,
            openClawIsInstalled: openClaw.isInstalled,
            openClawUserEnabled: appSettings.openClawEnabled,
            hermesIsInstalled: hermesService.isHookInstalled,
            hermesUserEnabled: appSettings.hermesEnabled
        )
        if case let .setupCards(hermes, openClawKind) = mode {
            VStack(spacing: 10) {
                HermesSetupCard(passive: hermes == .reenableCard)
                switch openClawKind {
                case .approvalCard:
                    OpenClawApprovalCard()
                case .installHintCard:
                    OpenClawInstallHintCard()
                case .reenableCard:
                    OpenClawReenableCard()
                }
            }
        }
    }

    var providerStatusList: some View {
        VStack(spacing: 0) {
            providerStatusRow(source: .claude, name: "Claude Code", kind: claudeKind) {
                appSettings.claudeEnabled = true
                if !aiService.claudeProvider.isHookInstalled {
                    aiService.claudeProvider.installHooks()
                }
            }
            Divider().overlay(NotchTheme.textTertiary.opacity(0.15))
            providerStatusRow(source: .gemini, name: "Gemini CLI", kind: geminiKind) {
                appSettings.geminiEnabled = true
                if !aiService.geminiProvider.isHookInstalled {
                    aiService.geminiProvider.installHooks()
                }
            }
            Divider().overlay(NotchTheme.textTertiary.opacity(0.15))
            providerStatusRow(source: .opencode, name: "opencode", kind: opencodeKind) {
                appSettings.opencodeEnabled = true
                if !aiService.opencodeProvider.isHookInstalled {
                    aiService.opencodeProvider.installHooks()
                }
            }
            Divider().overlay(NotchTheme.textTertiary.opacity(0.15))
            providerStatusRow(source: .zcode, name: "zcode", kind: zcodeKind) {
                appSettings.zcodeEnabled = true
                if !aiService.zcodeProvider.isHookInstalled {
                    aiService.zcodeProvider.installHooks()
                }
            }
        }
        .notchCard(radius: 10, fill: NotchTheme.surface)
    }

    @ViewBuilder
    func providerStatusRow(
        source: AISource,
        name: String,
        kind: ProviderCardKind,
        onAction: @escaping () -> Void
    ) -> some View {
        let isPassive = kind == .reenable
        HStack(spacing: 10) {
            sourceIcon(source, size: 16)
                .opacity(isPassive ? 0.6 : 1.0)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPassive ? NotchTheme.textSecondary : NotchTheme.textPrimary)
            Spacer(minLength: 8)
            switch kind {
            case .ready:
                HStack(spacing: 5) {
                    Circle()
                        .fill(sourceTint(source))
                        .frame(width: 6, height: 6)
                    Text("ai.ready")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchTheme.textSecondary)
                }
            case .install:
                Button(action: onAction) {
                    Text("ai.install_hooks")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(NotchTheme.accent.opacity(0.18)))
                .clipShape(Capsule())
                .foregroundStyle(NotchTheme.accent)
            case .reenable:
                Button(action: onAction) {
                    Text("ai.enable")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(Capsule().stroke(NotchTheme.accent.opacity(0.55), lineWidth: 1))
                .clipShape(Capsule())
                .foregroundStyle(NotchTheme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    var serverStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(aiService.serverRunning ? Color.green : NotchTheme.accent)
                .frame(width: 6, height: 6)
            Text(aiService.serverRunning ? "ai.unix_socket_ready" : "ai.hook_service_not_started")
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textTertiary)
        }
        .padding(.top, 4)
    }
}
