import SwiftUI

struct SystemTab: View {
    @Environment(SystemService.self) var systemService

    private var memoryRatio: Double {
        guard systemService.memoryTotal > 0 else { return 0 }
        return Double(systemService.memoryUsed) / Double(systemService.memoryTotal)
    }

    private var diskUsed: UInt64 {
        systemService.diskTotal - systemService.diskFree
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            cpuRow
            memoryRow
            batteryRow
            diskRow
        }
        .padding(.horizontal, 4)
    }

    // MARK: - CPU

    private var cpuRow: some View {
        HStack(spacing: 8) {
            Text("CPU")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 44, alignment: .leading)

            Text(String(format: "%.0f%%", systemService.cpuUsage))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 38, alignment: .trailing)

            cpuSparkline
                .frame(maxWidth: .infinity)
        }
    }

    private var cpuSparkline: some View {
        Canvas { context, size in
            let history = systemService.cpuHistory
            guard history.count > 1 else { return }

            let points = history.enumerated().map { index, value in
                CGPoint(
                    x: size.width * CGFloat(index) / CGFloat(history.count - 1),
                    y: size.height * (1 - CGFloat(value / 100))
                )
            }

            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }

            context.stroke(
                path,
                with: .color(.white.opacity(0.6)),
                lineWidth: 1
            )
        }
        .frame(height: 20)
    }

    // MARK: - Memory

    private var memoryRow: some View {
        HStack(spacing: 8) {
            Text("Memory")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 44, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.15))
                    Capsule()
                        .fill(.white.opacity(0.6))
                        .frame(width: geo.size.width * CGFloat(memoryRatio))
                }
            }
            .frame(height: 6)

            Text("\(formatGB(systemService.memoryUsed))/\(formatGB(systemService.memoryTotal)) GB")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Battery

    private var batteryRow: some View {
        HStack(spacing: 8) {
            Text("Battery")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 44, alignment: .leading)

            Image(systemName: batteryIcon)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))

            Text("\(systemService.batteryLevel)%")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)

            Text(batteryStatus)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var batteryIcon: String {
        if systemService.isCharging {
            return "battery.100.bolt"
        }
        let level = systemService.batteryLevel
        switch level {
        case 0...12:   return "battery.0"
        case 13...37:  return "battery.25"
        case 38...62:  return "battery.50"
        case 63...87:  return "battery.75"
        default:       return "battery.100"
        }
    }

    private var batteryStatus: String {
        if systemService.isCharging {
            return String(localized: "充电中")
        }
        let minutes = systemService.timeRemaining
        if minutes > 0 {
            return String(localized: "剩余 \(minutes) 分钟")
        }
        return ""
    }

    // MARK: - Disk

    private var diskRow: some View {
        HStack(spacing: 8) {
            Text("Disk")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 44, alignment: .leading)

            Text("\(formatGB(diskUsed))/\(formatGB(systemService.diskTotal)) GB")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)

            Spacer()

            Text("\(formatGB(systemService.diskFree)) GB 可用")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Helpers

    private func formatGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.1f", gb)
    }
}
