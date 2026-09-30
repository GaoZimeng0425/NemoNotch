import SwiftUI

/// Dynamic-Island-style transient capsule at the collapsed notch: a
/// same-material shape springs open from the physical notch width to a
/// measured content width ("icon + text"), dwells (owned by the driving
/// service), then unmounts. Shared by the Bluetooth connect/disconnect
/// capsule (`BluetoothService.capsuleEvent`) and the charging capsule
/// (`HUDService.chargingCapsule`).
///
/// Mount/width mechanics: the content is width-measured
/// (`.fixedSize` + `.onGeometryChange`, same pattern as `AIStatusFABView` and
/// `NotchView.closedContentSize`); the capsule frame animates from
/// `notchSize.width` to that measured width via the notch's own open spring.
/// The content fades in slightly delayed so it never flashes at full capsule
/// width while the shape is still narrow. Non-interactive — hover-open
/// hit-testing lives in `NotchCoordinator` and only reads the physical notch
/// rect, so the widened black area stays click/hover-inert.
///
/// The silhouette is the shared `NotchShape` with the collapsed shell's
/// radii (top flare 6 / bottom corner 8), so the capsule reads as the notch
/// itself widening rather than a foreign pill hovering over it; the frame
/// carries the flare overhang (`+ topRadius * 2`) on top of the body width.
struct NotchCapsuleView: View {
    let icon: String
    let iconColor: Color
    let text: String
    /// Physical notch footprint — the capsule starts at this size and grows
    /// horizontally around the same top edge.
    let notchSize: CGSize

    @State private var opened = false
    @State private var contentShown = false
    @State private var measuredContentWidth: CGFloat?

    /// The collapsed-shell silhouette, shared with `NotchBackgroundView`.
    private var capsuleShape: NotchShape {
        NotchShape(
            topCornerRadius: NotchConstants.cornerRadiusTopClosed,
            bottomCornerRadius: NotchConstants.cornerRadiusBottomClosed
        )
    }

    private var capsuleWidth: CGFloat {
        max(notchSize.width, measuredContentWidth ?? 0)
    }

    var body: some View {
        ZStack {
            capsuleShape
                .fill(NotchTheme.panelBase)

            content
                .opacity(contentShown ? 1 : 0)
        }
        .frame(width: (opened ? capsuleWidth : notchSize.width) + NotchConstants.cornerRadiusTopClosed * 2)
        .frame(height: notchSize.height)
        .clipShape(capsuleShape)
        .overlay(capsuleShape.stroke(NotchTheme.stroke, lineWidth: 0.6))
        .onAppear {
            withAnimation(.spring(duration: NotchConstants.openSpringDuration, bounce: 0.1)) {
                opened = true
            }
            withAnimation(.easeIn(duration: 0.18).delay(0.1)) {
                contentShown = true
            }
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: NotchConstants.notchCapsuleIconSize, weight: .semibold))
                .foregroundStyle(iconColor)
            Text(text)
                .font(.system(size: NotchConstants.notchCapsuleFontSize, weight: .semibold))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, NotchConstants.notchCapsuleHPadding)
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            // Frame-by-frame tracking, deliberately NOT inside withAnimation —
            // the one spring lives on the `opened` toggle in onAppear.
            measuredContentWidth = width
        }
    }
}
