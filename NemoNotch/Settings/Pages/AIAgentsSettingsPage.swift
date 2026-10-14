import SwiftUI

/// AI 与 Agent:AI 悬浮胶囊 / 锁屏面板开关 + 各 provider 的
/// 安装/重装/卸载卡片(HookCard)+ OpenClaw 连接卡(ProviderCard)。
struct AIAgentsSettingsPage: View {
    @Environment(AppSettings.self) var appSettings
    @Environment(AICLIMonitorService.self) var aiService
    @Environment(HermesService.self) var hermesService
    @Environment(OpenClawService.self) var openClawService

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                // 快速开关:AI 悬浮胶囊 + 锁屏 AI 面板(从旧"Tab 管理"并入,
                // AI 相关设置集中在一页)。视觉与下方 provider 卡片同语言。
                aiSurfacesCard

                // Claude Code
                HookCard(
                    name: "Claude Code",
                    tint: ProviderTint.claude,
                    isInstalled: aiService.claudeProvider.isHookInstalled,
                    logo: { ClaudeCrabIcon(size: 20, color: ProviderTint.claude) },
                    onInstall: {
                        appSettings.claudeEnabled = true
                        aiService.claudeProvider.installHooks()
                    },
                    onUninstall: {
                        appSettings.claudeEnabled = false
                        aiService.claudeProvider.uninstallHooks()
                    }
                )

                // Gemini CLI
                HookCard(
                    name: "Gemini CLI",
                    tint: ProviderTint.gemini,
                    isInstalled: aiService.geminiProvider.isHookInstalled,
                    logo: {
                        Image(systemName: "sparkles")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(ProviderTint.gemini)
                    },
                    onInstall: {
                        appSettings.geminiEnabled = true
                        aiService.geminiProvider.installHooks()
                    },
                    onUninstall: {
                        appSettings.geminiEnabled = false
                        aiService.geminiProvider.uninstallHooks()
                    }
                )

                // opencode
                HookCard(
                    name: "opencode",
                    tint: ProviderTint.opencode,
                    isInstalled: aiService.opencodeProvider.isHookInstalled,
                    logo: { OpencodeLogoIcon(size: 19, color: ProviderTint.opencode) },
                    onInstall: {
                        appSettings.opencodeEnabled = true
                        aiService.opencodeProvider.installHooks()
                    },
                    onUninstall: {
                        appSettings.opencodeEnabled = false
                        aiService.opencodeProvider.uninstallHooks()
                    }
                )

                // zcode
                HookCard(
                    name: "zcode",
                    tint: ProviderTint.zcode,
                    isInstalled: aiService.zcodeProvider.isHookInstalled,
                    logo: { ZcodeLogoIcon(size: 19, color: ProviderTint.zcode) },
                    onInstall: {
                        appSettings.zcodeEnabled = true
                        aiService.zcodeProvider.installHooks()
                    },
                    onUninstall: {
                        appSettings.zcodeEnabled = false
                        aiService.zcodeProvider.uninstallHooks()
                    }
                )

                // Hermes Agent
                HookCard(
                    name: "Hermes Agent",
                    tint: ProviderTint.hermes,
                    isInstalled: hermesService.isHookInstalled,
                    logo: {
                        Image("HermesIcon")
                            .renderingMode(.original)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    },
                    onInstall: {
                        appSettings.hermesEnabled = true
                        hermesService.installHooks()
                    },
                    onUninstall: {
                        appSettings.hermesEnabled = false
                        hermesService.uninstallHooks()
                    }
                )

                // OpenClaw — connect/disconnect/revoke semantics rather than hooks.
                ProviderCard(
                    name: "OpenClaw",
                    tint: ProviderTint.openClaw,
                    isOn: openClawService.gatewayOnline,
                    onLabel: "settings.openclaw.connected \(openClawService.deviceIdShort)",
                    offLabel: "settings.openclaw.disconnected",
                    logo: {
                        Image(systemName: "brain")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(ProviderTint.openClaw)
                    },
                    actions: {
                        VStack(alignment: .trailing, spacing: 6) {
                            if appSettings.openClawEnabled {
                                Button("settings.openclaw.disconnect") {
                                    appSettings.openClawEnabled = false
                                    openClawService.disconnect()
                                }
                                .controlSize(.small)
                            } else {
                                Button("settings.openclaw.connect") {
                                    appSettings.openClawEnabled = true
                                    openClawService.connect()
                                }
                                .controlSize(.small)
                                .buttonStyle(.borderedProminent)
                            }

                            if openClawService.gatewayOnline {
                                Button("settings.openclaw.remove_device", role: .destructive) {
                                    openClawService.removeDeviceSelf()
                                }
                                .controlSize(.small)
                                .disabled(openClawService.isRemovingDevice)
                            }
                        }
                    }
                )

                Text("settings.hooks_description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)

                if aiService.serverRunning {
                    Label("settings.server_running", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // 顶部收紧:卡片页只需留出与标题条的血缘间距,不要 Form 式大 padding。
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    // MARK: - AI 悬浮表面开关

    /// AI 悬浮胶囊 + 锁屏 AI 面板开关,卡片外观与 provider 卡片一致。
    /// 标签在左、开关(.switch 样式,macOS 默认是复选框)在右的标准行。
    private var aiSurfacesCard: some View {
        VStack(spacing: 0) {
            aiSurfaceRow("settings.ai_status_fab.enabled", isOn: Binding(
                get: { appSettings.aiStatusFabEnabled },
                set: { appSettings.aiStatusFabEnabled = $0 }
            ))
            Divider().padding(.horizontal, 12)
            aiSurfaceRow("settings.lockscreen_ai.enabled", isOn: Binding(
                get: { appSettings.lockScreenAIPanelEnabled },
                set: { appSettings.lockScreenAIPanelEnabled = $0 }
            ))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func aiSurfaceRow(_ labelKey: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(LocalizedStringKey(labelKey))
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
