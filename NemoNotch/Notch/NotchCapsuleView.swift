import SwiftUI

/// Dynamic-Island-style transient capsule at the collapsed notch: a
/// same-material rounded rect springs open from the physical notch width to
/// a measured content width ("icon + text"), dwells (owned by the driving
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

    private var capsuleWidth: CGFloat {
        max(notchSize.width, measuredContentWidth ?? 0)
    }

    var body: some View {
        ZStack {
            UnevenCornerRectangle(
                topRadius: NotchConstants.cornerRadiusTopClosed,
                bottomRadius: NotchConstants.cornerRadiusBottomClosed
            )
            .fill(NotchTheme.panelBase)
            .overlay(
                UnevenCornerRectangle(
                    topRadius: NotchConstants.cornerRadiusTopClosed,
                    bottomRadius: NotchConstants.cornerRadiusBottomClosed
                )
                .stroke(NotchTheme.stroke, lineWidth: 0.6)
            )

            content
                .opacity(contentShown ? 1 : 0)
        }
        .frame(width: opened ? capsuleWidth : notchSize.width)
        .frame(height: notchSize.height)
        .clipped()
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

/// Rounded rectangle with separate top/bottom corner radii, matching the
/// collapsed notch's silhouette (top 6 / bottom 8) so the capsule reads as
/// the notch widening rather than a foreign pill hovering over it.
struct UnevenCornerRectangle: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 2, rect.height / 2)
        let b = min(bottomRadius, rect.width / 2, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.addArc(
            center: CGPoint(x: rect.maxX - t, y: rect.minY + t), radius: t,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: true
        )
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
        p.addArc(
            center: CGPoint(x: rect.maxX - b, y: rect.maxY - b), radius: b,
            startAngle: .degrees(0), endAngle: .degrees(90), clockwise: true
        )
        p.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.minX + b, y: rect.maxY - b), radius: b,
            startAngle: .degrees(90), endAngle: .degrees(180), clockwise: true
        )
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + t))
        p.addArc(
            center: CGPoint(x: rect.minX + t, y: rect.minY + t), radius: t,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: true
        )
        p.closeSubpath()
        return p
    }
}
