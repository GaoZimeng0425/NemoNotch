import SwiftUI

// 设置窗共享的视觉组件与品牌色令牌。窗口跟随系统外观(浅/深色),
// 这里的颜色必须用系统语义色或自带明暗两套 —— 不能用仅暗色的 NotchTheme。

// MARK: - 设计令牌

/// 设置窗的圆角/间距令牌:详情大卡、页内分组卡、行内距统一从这里取值,
/// 各页不再自造常数。
enum SettingsMetrics {
    /// 详情区大玻璃卡的圆角。
    static let detailCardRadius: CGFloat = 16
    /// 页内分组卡(provider 卡、开关组卡)的圆角。
    static let cardRadius: CGFloat = 14
    /// 分组卡内部行 的左右内距。
    static let rowHPadding: CGFloat = 12
}

// MARK: - 侧栏搜索条

/// Atoll 式侧栏顶部搜索条:放大镜 + plain TextField + 清除钮,圆角材质底。
/// 实时驱动 `SettingsSearchModel.query`(侧栏过滤),回车触发 `onSubmit`。
struct SettingsSidebarSearchBar: View {
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("settings.search.placeholder", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("settings.search.clear"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary)
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

// MARK: - 侧栏图标

/// 系统设置风格的彩色渐变图标方块:渐变底 + 白色 SF Symbol + 0.5pt 高光
/// 描边 + 柔影。渐变色固定(不随明暗切换),与 macOS 系统设置的侧栏图标
/// 行为一致。
struct SidebarIconView: View {
    let symbol: String
    let tintA: Color
    let tintB: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [tintA, tintB],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5)
            )
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
            }
            .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
            // 装饰性图标:行文本自身就是完整的可访问性标签。
            .accessibilityHidden(true)
    }
}

// MARK: - Provider 品牌色

/// Per-provider brand tints, tuned to read on both light and dark windows
/// (the Settings window follows the system appearance, unlike the dark-only
/// NotchTheme used inside the notch panel).
enum ProviderTint {
    static let claude = Color(red: 0.93, green: 0.49, blue: 0.19)
    static let gemini = Color(red: 0.26, green: 0.52, blue: 0.96)
    static let opencode = Color(red: 0.30, green: 0.66, blue: 0.40)
    static let zcode = Color(red: 0.11, green: 0.44, blue: 0.96)
    static let hermes = Color(red: 0.52, green: 0.43, blue: 0.92)
    static let openClaw = Color(red: 0.14, green: 0.62, blue: 0.60)
}

// MARK: - Provider 卡片

/// A hook-based provider card with install / reinstall / uninstall actions.
struct HookCard<Logo: View>: View {
    let name: String
    let tint: Color
    let isInstalled: Bool
    @ViewBuilder let logo: () -> Logo
    let onInstall: () -> Void
    let onUninstall: () -> Void

    var body: some View {
        ProviderCard(
            name: name,
            tint: tint,
            isOn: isInstalled,
            onLabel: "settings.status.installed",
            offLabel: "settings.status.not_installed",
            logo: logo,
            actions: {
                VStack(alignment: .trailing, spacing: 6) {
                    if isInstalled {
                        Button("settings.reinstall", action: onInstall)
                            .controlSize(.small)
                        Button("settings.uninstall_hooks", role: .destructive, action: onUninstall)
                            .controlSize(.small)
                    } else {
                        Button("settings.install_hooks", action: onInstall)
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        )
    }
}

/// Generic provider card shell: tinted logo chip + name + on/off status row
/// + trailing actions. Used for both hook providers and OpenClaw.
struct ProviderCard<Logo: View, Actions: View>: View {
    let name: String
    let tint: Color
    let isOn: Bool
    let onLabel: LocalizedStringKey
    let offLabel: LocalizedStringKey
    @ViewBuilder let logo: () -> Logo
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(tint.opacity(0.32), lineWidth: 1)
                )
                .frame(width: 40, height: 40)
                .overlay { logo() }

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isOn ? Color.green : Color.secondary)
                    Text(isOn ? onLabel : offLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            actions
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
