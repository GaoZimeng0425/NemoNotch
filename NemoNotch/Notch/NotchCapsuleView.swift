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
/// The silhouette is the shared `BezelShape` with the collapsed shell's
/// radii (top flare 6 / bottom corner 8), so the capsule reads as the notch
/// itself widening rather than a foreign pill hovering over it; the frame
/// carries the flare overhang (`+ topRadius * 2`) on top of the body width.
struct NotchCapsuleView: View {
    let capsule: NotchCapsule
    /// Physical notch footprint — the capsule starts at this size and grows
    /// horizontally around the same top edge.
    let notchSize: CGSize

    @State private var appeared = false
    @State private var opened = false
    @State private var contentShown = false
    @State private var measuredContentWidth: CGFloat?

    /// The collapsed-shell silhouette, shared with `NotchBackgroundView`.
    private var capsuleShape: BezelShape {
        BezelShape(
            edge: .top,
            flare: NotchConstants.cornerRadiusTopClosed,
            corner: NotchConstants.cornerRadiusBottomClosed
        )
    }

    private var capsuleWidth: CGFloat {
        max(notchSize.width, measuredContentWidth ?? 0)
    }

    private var openSpring: Animation {
        .spring(duration: NotchConstants.openSpringDuration, bounce: 0.1)
    }

    var body: some View {
        ZStack {
            capsuleShape
                .fill(NotchTheme.panelBase)

            // A newer event swaps only the content (keyed by event id) inside
            // the one live shape: no second capsule fading over the first,
            // and the width springs to the new measurement.
            content
                .id(capsule.id)
                .transition(.opacity)
                .opacity(contentShown ? 1 : 0)
        }
        .frame(width: (opened ? capsuleWidth : notchSize.width) + NotchConstants.cornerRadiusTopClosed * 2)
        .frame(height: notchSize.height)
        .clipShape(capsuleShape)
        .overlay(capsuleShape.stroke(NotchTheme.stroke, lineWidth: 0.6))
        .onAppear {
            appeared = true
            openIfReady()
        }
    }

    /// The open spring starts only once BOTH the view is on screen and the
    /// content width is known — whichever lands second fires it — so the
    /// spring always targets the real width instead of the notch width with
    /// the measurement snapping in afterwards.
    private func openIfReady() {
        guard appeared, measuredContentWidth != nil, !opened else { return }
        withAnimation(openSpring) {
            opened = true
        }
        withAnimation(.easeIn(duration: 0.18).delay(0.1)) {
            contentShown = true
        }
    }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: capsule.icon)
                .font(.system(size: NotchConstants.notchCapsuleIconSize, weight: .semibold))
                .foregroundStyle(capsule.iconColor)
            Text(capsule.text)
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
            if opened {
                // Content swapped in place (newer event): spring to fit it.
                withAnimation(openSpring) { measuredContentWidth = width }
            } else {
                measuredContentWidth = width
                openIfReady()
            }
        }
    }
}

/// What the notch capsule shows. Charging wins over Bluetooth, and both feed
/// one mount slot in `NotchView`, so a switch between them is a content swap
/// inside a single shape rather than two capsules cross-fading on the spot.
struct NotchCapsule: Equatable {
    let id: UUID
    let icon: String
    let iconColor: Color
    let text: String

    static func current(charging: ChargingCapsuleEvent?, bluetooth: BluetoothDeviceEvent?) -> NotchCapsule? {
        if let charging {
            return NotchCapsule(
                id: charging.id,
                icon: charging.externalConnected ? "bolt.fill" : "battery.100",
                iconColor: charging.externalConnected ? NotchTheme.chargingGreen : NotchTheme.accent,
                text: charging.text
            )
        }
        if let bluetooth {
            return NotchCapsule(
                id: bluetooth.id,
                icon: "headphones",
                iconColor: NotchTheme.accent,
                text: bluetooth.text
            )
        }
        return nil
    }
}
