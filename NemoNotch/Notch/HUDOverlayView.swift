import SwiftUI

struct HUDOverlayView: View {
    let type: HUDService.HUDType
    let value: Float

    private var icon: String {
        switch type {
        case .volume: volumeIcon
        case .battery(let charging):
            charging ? "battery.100.bolt" : batteryIconName
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
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: NotchConstants.hudIconSize, alignment: .center)

            progressBar

            Text(percentageText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.horizontal, NotchConstants.hudHorizontalPadding)
        .frame(height: NotchConstants.hudHeight)
        .background(.black.opacity(0.85))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.2))

                Capsule()
                    .fill(.white.opacity(0.8))
                    .frame(width: max(0, geo.size.width * CGFloat(value)))
            }
        }
        .frame(height: NotchConstants.hudProgressBarHeight)
        .frame(maxWidth: .infinity)
    }
}
