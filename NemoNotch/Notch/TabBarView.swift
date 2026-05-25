import SwiftUI

/// Tab icons strip that lives in the notch's left chin area.
///
/// Owns its own sizing (icon size, spacing, font) so layout decisions stay in
/// one place. Each tab's hit area is expanded with padding (absorbing the
/// visual gap) so users don't have to land on the SF Symbol glyph itself.
///
/// Placement: caller passes `trailingX` — the x-coord where the rightmost
/// icon's right edge should sit (typically `notchLeftEdge - 8`). The component
/// centers itself horizontally based on its own visual width.
struct NotchTabBar: View {
    let tabs: [Tab]
    let selected: Tab
    let trailingX: CGFloat
    let centerY: CGFloat
    let onSelect: (Tab) -> Void

    var body: some View {
        let count = tabs.count
        let iconSize: CGFloat = count > 5 ? 16 : 18
        let spacing: CGFloat = count > 5 ? 3 : 4
        let fontSize: CGFloat = count > 5 ? 10 : 11
        let visualWidth = CGFloat(count) * iconSize + CGFloat(count - 1) * spacing
        // Each tab absorbs half the original HStack spacing into its own
        // horizontal padding, so the visible gap stays identical while the
        // hit-test rect grows. Vertical padding adds finger-friendly room.
        let hitHPadding = spacing / 2
        let hitVPadding: CGFloat = 4

        return HStack(spacing: 0) {
            ForEach(tabs) { tab in
                tabButton(
                    tab: tab,
                    iconSize: iconSize,
                    fontSize: fontSize,
                    hitHPadding: hitHPadding,
                    hitVPadding: hitVPadding
                )
            }
        }
        .position(x: trailingX - visualWidth / 2, y: centerY)
    }

    private func tabButton(
        tab: Tab,
        iconSize: CGFloat,
        fontSize: CGFloat,
        hitHPadding: CGFloat,
        hitVPadding: CGFloat
    ) -> some View {
        let isSelected = tab == selected
        return Button {
            onSelect(tab)
        } label: {
            Image(systemName: tab.icon)
                .font(.system(size: fontSize, weight: isSelected ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isSelected ? NotchTheme.textPrimary : NotchTheme.textTertiary)
                .frame(width: iconSize, height: iconSize)
                .background(
                    RoundedRectangle(cornerRadius: iconSize / 3, style: .continuous)
                        .fill(isSelected ? NotchTheme.surfaceEmphasis : .clear)
                )
                .padding(.horizontal, hitHPadding)
                .padding(.vertical, hitVPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
