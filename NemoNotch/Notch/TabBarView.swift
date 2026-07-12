import SwiftUI

/// The single-row chin bar that straddles the hardware notch when expanded.
///
/// Layout is a three-column `HStack(spacing: 0)` — the same pattern as
/// boring.notch's `BoringHeader`:
///
///     ┌──────────────┬────────────────┬──────────────┐
///     │  left (flex) │  middle (fixed)│  right (flex)│
///     │  tabs ◀      │  = notch width │       ▶ close│
///     │  .leading    │  (clear spacer)│  .trailing   │
///     └──────────────┴────────────────┴──────────────┘
///        maxWidth: .infinity   width: notchW   maxWidth: .infinity
///
/// Because the outer frame is `openedWidth` and the middle column is fixed at
/// the hardware notch width, the two flex columns each receive exactly
/// `(openedWidth - notchWidth) / 2` points. Tab and action content is
/// hard-constrained inside those allocations, so it can **never** spill past
/// the notch shell — the original failure mode with absolute `.position()`.
struct NotchChinBar: View {
    let tabs: [Tab]
    let selected: Tab
    let openedWidth: CGFloat
    let notchWidth: CGFloat
    let chinHeight: CGFloat
    let onSelect: (Tab) -> Void
    let onClose: () -> Void

    @Namespace private var capsuleAnimation
    @State private var hoveredTab: Tab?
    @State private var hoveredAction: ActionKey?
    @State private var bounceTriggers: [Tab: Int] = [:]

    private enum ActionKey: String { case settings, close }

    var body: some View {
        HStack(spacing: 0) {
            tabStrip
                .frame(maxWidth: .infinity, alignment: .trailing)

            // Middle column: a clear spacer exactly as wide as the hardware
            // notch, so tab/action content never sits under the notch itself.
            Color.clear
                .frame(width: notchWidth, height: chinHeight)

            actionStrip
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: openedWidth, height: chinHeight)
    }

    // MARK: - Tabs (left column)

    @ViewBuilder
    private var tabStrip: some View {
        if tabs.isEmpty {
            EmptyView()
        } else {
            let sideWidth = (openedWidth - notchWidth) / 2
            let spacing: CGFloat = 2
            let capsuleHeight: CGFloat = 24
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
    /// would otherwise overflow the left column's allocation.
    private func idealCapsuleWidth(sideWidth: CGFloat, count: Int, spacing: CGFloat) -> CGFloat {
        let ideal: CGFloat = 30
        let available = sideWidth - CGFloat(max(0, count - 1)) * spacing
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
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .rounded))
                .symbolEffect(.bounce.down, value: bounceTriggers[tab, default: 0])
                .foregroundStyle(isSelected ? NotchTheme.accent : NotchTheme.textSecondary)
                .frame(width: width, height: height)
                .background(alignment: .center) {
                    // Sliding selection capsule: only the selected tab's capsule
                    // is visible and acts as the matched-geometry source, so
                    // it glides between tabs on selection change.
                    if isSelected {
                        Capsule(style: .continuous)
                            .fill(NotchTheme.surfaceEmphasis)
                            .matchedGeometryEffect(id: "tabSelection", in: capsuleAnimation)
                    } else if isHovered {
                        Capsule(style: .continuous)
                            .fill(NotchTheme.surface)
                    }
                }
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(NotchChinButtonStyle())
        .onHover { hovering in
            hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
        }
    }

    // MARK: - Actions (right column)

    @ViewBuilder
    private var actionStrip: some View {
        let capsuleHeight: CGFloat = 24
        let capsuleWidth: CGFloat = 30

        HStack(spacing: 2) {
            SettingsLink {
                actionLabel(icon: "gearshape", width: capsuleWidth, height: capsuleHeight)
            }
            .buttonStyle(NotchChinButtonStyle())
            .onHover { hovering in
                hoveredAction = hovering ? .settings : (hoveredAction == .settings ? nil : hoveredAction)
            }

            Button(action: onClose) {
                actionLabel(icon: "xmark", width: capsuleWidth, height: capsuleHeight)
            }
            .buttonStyle(NotchChinButtonStyle())
            .onHover { hovering in
                hoveredAction = hovering ? .close : (hoveredAction == .close ? nil : hoveredAction)
            }
        }
    }

    private func actionLabel(icon: String, width: CGFloat, height: CGFloat) -> some View {
        let isHovered = hoveredAction == (icon == "gearshape" ? ActionKey.settings : ActionKey.close)
        return Image(systemName: icon)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(NotchTheme.textSecondary)
            .frame(width: width, height: height)
            .background(alignment: .center) {
                if isHovered {
                    Capsule(style: .continuous)
                        .fill(NotchTheme.surface)
                }
            }
            .contentShape(Capsule(style: .continuous))
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
