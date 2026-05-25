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

struct PermissionCard: View {
    let icon: String
    let titleKey: LocalizedStringKey
    let detailKey: LocalizedStringKey
    let status: PermissionStatus
    let primary: PermissionRequestability
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(NotchTheme.accent)
            Text(titleKey)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .multilineTextAlignment(.center)
            Text(detailKey)
                .font(.system(size: 9))
                .foregroundStyle(NotchTheme.textSecondary)
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
                .background(Capsule().fill(NotchTheme.accent))
                .foregroundStyle(Color.black.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(labelKey: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(labelKey)
                .font(.system(size: 10))
                .foregroundStyle(NotchTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
    }
}
