import SwiftUI

/// The single-row chin bar that straddles the hardware notch when expanded.
///
/// Layout is a three-column `HStack(spacing: 0)` — the same pattern as
/// boring.notch's `BoringHeader`:
///
///     ┌──────────────┬────────────────┬──────────────────────┐
///     │  left (flex) │  middle (fixed)│  right (flex)        │
///     │      tabs ◀  │  = notch width │  ▶ tabs + settings + │
///     │  .trailing   │  (clear spacer)│  quit  .leading      │
///     └──────────────┴────────────────┴──────────────────────┘
///        maxWidth: .infinity   width: notchW   maxWidth: .infinity
///
/// Both flex columns align toward the center notch (left `.trailing`,
/// right `.leading`), so content hugs the notch edges with empty space on
/// the outside. Each flex column also carries edge padding so content never
/// touches the shell's outer edge. Tabs split between the two columns via
/// `Tab.chinPlacement`: regular content tabs on the left, pomodoro joins the
/// settings/quit cluster on the right.
struct NotchChinBar: View {
    let tabs: [Tab]
    let selected: Tab
    let openedWidth: CGFloat
    let notchWidth: CGFloat
    let chinHeight: CGFloat
    let onSelect: (Tab) -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    @Namespace private var capsuleAnimation
    @State private var hoveredTab: Tab?
    @State private var hoveredAction: ActionKey?
    @State private var bounceTriggers: [Tab: Int] = [:]

    private enum ActionKey: String { case settings, quit }

    /// Selection/hover background corner radius — deliberately squarer than a
    /// capsule so the tabs don't read as pills.
    private static let capsuleCornerRadius: CGFloat = 7

    /// Gap between each tab group and the notch it hugs (both flex columns
    /// align toward the center, so this is the notch-side padding on each).
    private static let chinEdgePadding: CGFloat = 16

    private var leftTabs: [Tab] {
        tabs.filter { $0.chinPlacement == .left }
    }

    private var rightTabs: [Tab] {
        tabs.filter { $0.chinPlacement == .right }
    }

    var body: some View {
        HStack(spacing: 0) {
            tabStrip(leftTabs)
                .padding(.trailing, Self.chinEdgePadding)
                .frame(maxWidth: .infinity, alignment: .trailing)

            // Middle column: a clear spacer exactly as wide as the hardware
            // notch, so tab/action content never sits under the notch itself.
            Color.clear
                .frame(width: notchWidth, height: chinHeight)

            rightColumn
                .padding(.leading, Self.chinEdgePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: openedWidth, height: chinHeight)
    }

    // MARK: - Tab strip (shared by both columns)

    @ViewBuilder
    private func tabStrip(_ tabs: [Tab]) -> some View {
        if tabs.isEmpty {
            EmptyView()
        } else {
            let sideWidth = (openedWidth - notchWidth) / 2
            let spacing: CGFloat = 6
            let capsuleHeight: CGFloat = 26
            let capsuleWidth = idealCapsuleWidth(
                sideWidth: sideWidth,
                count: tabs.count,
                spacing: spacing
            )

            HStack(spacing: spacing) {
                ForEach(tabs) { tab in
                    tabCapsule(
                        tab: tab,
                        width: capsuleWidth,
                        height: capsuleHeight
                    )
                }
            }
        }
    }

    /// Capsule width that stays comfortable but clamps down when many tabs
    /// would otherwise overflow a flex column's allocation. Accounts for the
    /// edge padding so the total never exceeds the column.
    private func idealCapsuleWidth(sideWidth: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        let ideal: CGFloat = 30
        let available = sideWidth - Self.chinEdgePadding - CGFloat(max(0, count - 1)) * spacing
        let perTab = count > 0 ? available / CGFloat(count) : ideal
        return max(18, min(ideal, floor(perTab)))
    }

    private func tabCapsule(tab: Tab, width: CGFloat, height: CGFloat) -> some View {
        let isSelected = tab == selected
        let isHovered = hoveredTab == tab
        return Button {
            bounceTriggers[tab, default: 0] += 1
            withAnimation(.spring(duration: NotchConstants.tabSwitchSpringDuration, bounce: NotchConstants.tabSwitchSpringBounce)) {
                onSelect(tab)
            }
        } label: {
            Image(systemName: tab.icon)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                .symbolEffect(.bounce.down, value: bounceTriggers[tab, default: 0])
                .foregroundStyle(isSelected ? NotchTheme.textPrimary : NotchTheme.textSecondary)
                .frame(width: width, height: height)
                .background(alignment: .center) {
                    // Sliding selection capsule: only the selected tab's shape
                    // is visible and acts as the matched-geometry source, so
                    // it glides between tabs on selection change. The accent
                    // tint + matching glow make the selection read as "lit".
                    if isSelected {
                        RoundedRectangle(cornerRadius: Self.capsuleCornerRadius, style: .continuous)
                            .fill(NotchTheme.accent.opacity(0.22))
                            .shadow(color: NotchTheme.accent.opacity(0.35), radius: 8)
                            .matchedGeometryEffect(id: "tabSelection", in: capsuleAnimation)
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: Self.capsuleCornerRadius, style: .continuous)
                            .fill(NotchTheme.surface)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Self.capsuleCornerRadius, style: .continuous))
        }
        .buttonStyle(NotchChinButtonStyle())
        .onHover { hovering in
            hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
        }
    }

    // MARK: - Right column (right-side tabs + settings + quit)

    @ViewBuilder
    private var rightColumn: some View {
        let capsuleHeight: CGFloat = 26
        let capsuleWidth: CGFloat = 30

        HStack(spacing: 2) {
            // Right-side tabs (e.g. pomodoro) first, closest to the notch.
            ForEach(rightTabs) { tab in
                tabCapsule(tab: tab, width: capsuleWidth, height: capsuleHeight)
            }

            Button(action: onSettings) {
                actionLabel(icon: "gearshape", key: .settings, width: capsuleWidth, height: capsuleHeight)
            }
            .buttonStyle(NotchChinButtonStyle())
            .onHover { hovering in
                hoveredAction = hovering ? .settings : (hoveredAction == .settings ? nil : hoveredAction)
            }

            Button(action: onQuit) {
                actionLabel(icon: "power", key: .quit, width: capsuleWidth, height: capsuleHeight)
            }
            .buttonStyle(NotchChinButtonStyle())
            .onHover { hovering in
                hoveredAction = hovering ? .quit : (hoveredAction == .quit ? nil : hoveredAction)
            }
        }
    }

    private func actionLabel(icon: String, key: ActionKey, width: CGFloat, height: CGFloat) -> some View {
        let isHovered = hoveredAction == key
        return Image(systemName: icon)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(NotchTheme.textSecondary)
            .frame(width: width, height: height)
            .background(alignment: .center) {
                if isHovered {
                    RoundedRectangle(cornerRadius: Self.capsuleCornerRadius, style: .continuous)
                        .fill(NotchTheme.surface)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: Self.capsuleCornerRadius, style: .continuous))
    }
}

/// Shared press feedback for chin buttons (tabs + actions): gentle scale-down
/// + dim while held. Hover/selection capsule fills are handled in each label
/// so the full capsule width gets the background, not just the icon.
private struct NotchChinButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
