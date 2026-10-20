import SwiftUI

/// Three-state representation of any kind of permission this app cares about.
/// `.authorized` is intentionally absent — the parent view is expected to NOT
/// render a `PermissionCard` when the underlying permission is granted, and
/// to render normal feature content instead.
enum PermissionStatus: Equatable {
    case notDetermined
    case denied
    case restricted // rare; treated like .denied
}

/// How the primary CTA should behave when the permission is in
/// `.notDetermined`. Once `.denied`, the card always falls back to "open
/// System Settings" regardless of this value, because the system dialog
/// can't be re-triggered programmatically.
enum PermissionRequestability {
    case programmatic(() -> Void)
    case settingsOnly
}

/// `PermissionCard` 的宿主环境决定配色:
/// - `.dark`(默认):刘海面板内的暗色玻璃上,沿用 NotchTheme 深色配色;
/// - `.adaptive`:设置窗(跟随系统浅/深色外观),系统语义色,两种外观都对。
enum PermissionCardStyle {
    case dark
    case adaptive
}

struct PermissionCard: View {
    let icon: String
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey
    let status: PermissionStatus
    let primary: PermissionRequestability
    let openSettings: () -> Void
    var style: PermissionCardStyle = .dark

    private var accent: Color {
        style == .dark ? NotchTheme.accent : .accentColor
    }

    private var titleColor: Color {
        style == .dark ? NotchTheme.textPrimary : .primary
    }

    private var detailColor: Color {
        style == .dark ? NotchTheme.textSecondary : .secondary
    }

    /// 设置窗行高比刘海卡片大,adaptive 档顺带放大一档字号。
    private var titleSize: CGFloat {
        style == .dark ? 11 : 12
    }

    private var detailSize: CGFloat {
        style == .dark ? 9 : 10
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(accent)
            Text(titleKey)
                .font(.system(size: titleSize, weight: .semibold))
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.center)
            Text(detailKey)
                .font(.system(size: detailSize))
                .foregroundStyle(detailColor)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            ctaRow
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var ctaRow: some View {
        switch (status, primary) {
        case let (.notDetermined, .programmatic(action)):
            HStack(spacing: 6) {
                primaryButton(labelKey: "permission.grant", action: action)
                secondaryButton(labelKey: "permission.open_settings", action: openSettings)
            }
        case (.notDetermined, .settingsOnly):
            primaryButton(labelKey: "permission.open_settings", action: openSettings)
        case (.denied, _), (.restricted, _):
            primaryButton(labelKey: "permission.open_settings", action: openSettings)
        }
    }

    private func primaryButton(labelKey: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(labelKey)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(accent))
                .foregroundStyle(style == .dark ? Color.black.opacity(0.85) : Color.white)
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(labelKey: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(labelKey)
                .font(.system(size: 10))
                .foregroundStyle(detailColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }
}
