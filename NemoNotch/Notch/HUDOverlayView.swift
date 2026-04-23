import SwiftUI

struct HUDOverlayView: View {
    let type: HUDService.HUDType
    let value: Float

    private static let accentColor = NotchTheme.accent
    private static let segmentCount = 20

    private var icon: String {
        switch type {
        case .volume: volumeIcon
        case .brightness: brightnessIcon
        case .battery(let charging):
            charging ? "bolt.fill" : batteryIconName
        }
    }

    private var volumeIcon: String {
        switch value {
        case 0: "speaker.slash.fill"
        case ..<0.33: "speaker.wave.1.fill"
        case ..<0.67: "speaker.wave.2.fill"
        default: "speaker.wave.3.fill"
        }
    }

    private var brightnessIcon: String {
        switch value {
        case 0: "sun.min.fill"
        case ..<0.5: "sun.and.horizon.fill"
        default: "sun.max.fill"
        }
    }

    private var batteryIconName: String {
        switch value {
        case ..<0.13: "battery.0"
        case 0.13..<0.38: "battery.25"
        case 0.38..<0.63: "battery.50"
        case 0.63..<0.88: "battery.75"
        default: "battery.100"
        }
    }

    private var percentageText: String {
        "\(Int(value * 100))%"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Self.accentColor)
                .frame(width: 18, alignment: .center)

            segmentedBar

            Text(percentageText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.accentColor)
                .monospacedDigit()
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, NotchConstants.hudHorizontalPadding)
        .frame(height: NotchConstants.hudHeight)
        .background(.black)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(NotchTheme.stroke, lineWidth: 0.6)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, y: 4)
    }

    private var segmentedBar: some View {
        HStack(spacing: NotchConstants.hudSegmentSpacing) {
            ForEach(0..<Self.segmentCount, id: \.self) { index in
                let threshold = Float(index + 1) / Float(Self.segmentCount)
                RoundedRectangle(cornerRadius: NotchConstants.hudSegmentCornerRadius)
                    .fill(
                        value >= threshold
                            ? Self.accentColor
                            : Self.accentColor.opacity(0.15)
                    )
                    .frame(
                        width: NotchConstants.hudSegmentWidth,
                        height: NotchConstants.hudSegmentHeight
                    )
                    .animation(.easeInOut(duration: 0.15).delay(Double(index) * 0.01), value: value)
            }
        }
    }
}
