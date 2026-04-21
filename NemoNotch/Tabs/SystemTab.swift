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
        VStack(alignment: .leading, spacing: 6) {
            cpuRow
            memoryRow
            batteryRow
            diskRow
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
    }

    // MARK: - CPU

    private var cpuRow: some View {
        HStack(spacing: 8) {
            Text("CPU")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 40, alignment: .leading)

            Text(String(format: "%.0f%%", systemService.cpuUsage))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(cpuColor)
                .frame(width: 38, alignment: .trailing)

            cpuSparkline
                .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(rowBackground)
    }

    private var cpuColor: Color {
        let usage = systemService.cpuUsage
        if usage > 80 { return .red }
        if usage > 50 { return .yellow }
        return .white
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

            var fillPath = Path()
            fillPath.move(to: CGPoint(x: points[0].x, y: size.height))
            fillPath.addLine(to: points[0])
            for point in points.dropFirst() {
                fillPath.addLine(to: point)
            }
            fillPath.addLine(to: CGPoint(x: points.last!.x, y: size.height))
            fillPath.closeSubpath()

            context.fill(
                fillPath,
                with: .color(.white.opacity(0.08))
            )

            var linePath = Path()
            linePath.move(to: points[0])
            for point in points.dropFirst() {
                linePath.addLine(to: point)
            }

            context.stroke(
                linePath,
                with: .color(.white.opacity(0.5)),
                lineWidth: 1
            )
        }
        .frame(height: 22)
    }

    // MARK: - Memory

    private var memoryRow: some View {
        HStack(spacing: 8) {
            Text("RAM")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 40, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.12))
                    Capsule()
                        .fill(memoryGradient)
                        .frame(width: geo.size.width * CGFloat(memoryRatio))
                }
            }
            .frame(height: 6)

            Text("\(formatGB(systemService.memoryUsed))/\(formatGB(systemService.memoryTotal))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(8)
        .background(rowBackground)
    }

    private var memoryGradient: Color {
        let ratio = memoryRatio
        if ratio > 0.85 { return .red }
        if ratio > 0.65 { return .yellow }
        return .white.opacity(0.5)
    }

    // MARK: - Battery

    private var batteryRow: some View {
        HStack(spacing: 8) {
            Text("BAT")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 40, alignment: .leading)

            Image(systemName: batteryIcon)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))

            Text("\(systemService.batteryLevel)%")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            Text(batteryStatus)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(8)
        .background(rowBackground)
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
            return "充电中"
        }
        let minutes = systemService.timeRemaining
        if minutes > 0 {
            return "剩余 \(minutes) 分钟"
        }
        return ""
    }

    // MARK: - Disk

    private var diskRow: some View {
        HStack(spacing: 8) {
            Text("DISK")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 40, alignment: .leading)

            Text("\(formatGB(diskUsed))/\(formatGB(systemService.diskTotal))")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white)

            Spacer(minLength: 0)

            Text("\(formatGB(systemService.diskFree)) GB 可用")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(8)
        .background(rowBackground)
    }

    // MARK: - Helpers

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.white.opacity(0.06))
    }

    private func formatGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.0f", gb)
    }
}
