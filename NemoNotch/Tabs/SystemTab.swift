import SwiftUI

/// System monitoring tab: three metric cards with sparkline history (CPU /
/// Memory / Network dual-quadrant), the per-process CPU ranking, and a
/// battery + disk footer strip. History buffers live on `SystemService`
/// (one sample per 2s poll, capped at 60) so graphs survive tab switches.
struct SystemTab: View {
    @Environment(SystemService.self) var systemService

    private let cpuColor = Color(red: 0.35, green: 0.62, blue: 1.0)
    private let memoryColor = Color(red: 0.36, green: 0.78, blue: 0.52)
    private let downloadColor = NotchTheme.accentText
    private let uploadColor = Color(red: 1.0, green: 0.42, blue: 0.35)

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    statCards
                    sectionHeader("Processes")
                    ForEach(systemService.topProcessesByCPU) { process in
                        processRow(process)
                    }
                }
                .padding(.horizontal, 4)
            }

            infoFooter
                .padding(.horizontal, 4)
                .padding(.bottom, 8)
        }
        .activates(systemService)
    }

    // MARK: - Stat Cards

    private var statCards: some View {
        HStack(spacing: 10) {
            SystemStatCard(
                icon: "cpu",
                title: "CPU",
                value: String(format: "%.0f%%", systemService.cpuUsage),
                valueColor: loadColor(systemService.cpuUsage)
            ) {
                MiniGraph(data: systemService.cpuHistory, color: cpuColor)
            }

            SystemStatCard(
                icon: "memorychip",
                title: "Memory",
                value: "\(formatGB(systemService.memoryUsed))/\(formatGB(systemService.memoryTotal))G",
                valueColor: NotchTheme.textPrimary
            ) {
                MiniGraph(data: systemService.memoryHistory, color: memoryColor)
            }

            SystemStatCard(
                icon: "network",
                title: "Network",
                value: "↓\(formatSpeed(systemService.downloadSpeed)) ↑\(formatSpeed(systemService.uploadSpeed))",
                valueColor: downloadColor,
                valueFont: .system(size: 11, weight: .semibold, design: .monospaced)
            ) {
                DualQuadrantGraph(
                    topData: systemService.downloadHistory,
                    bottomData: systemService.uploadHistory,
                    topColor: downloadColor,
                    bottomColor: uploadColor
                )
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(NotchTheme.textTertiary)
            .textCase(.uppercase)
            .padding(.leading, 2)
    }

    // MARK: - Process Row

    private func processRow(_ process: ProcessEntry) -> some View {
        HStack(spacing: 8) {
            if let icon = process.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 11))
                    .foregroundStyle(NotchTheme.textTertiary)
                    .frame(width: 20, height: 20)
            }

            Text(process.displayName)
                .font(.system(size: 12))
                .foregroundStyle(NotchTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)

            Text(formatMemory(process.memoryUsed))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(NotchTheme.textSecondary)

            Text(String(format: "%.1f%%", process.cpuUsage))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(loadColor(process.cpuUsage))
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(NotchTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(NotchTheme.stroke, lineWidth: 0.6)
                )
        )
    }

    // MARK: - Footer (battery + disk)

    private var infoFooter: some View {
        HStack(spacing: 0) {
            statusChip(
                systemImage: isCharging ? "battery.100.bolt" : batteryIcon,
                value: "\(systemService.batteryLevel)%"
            )
            Rectangle()
                .fill(NotchTheme.stroke)
                .frame(width: 0.6, height: 16)
            statusChip(
                systemImage: "internaldrive",
                value: "\(formatGB(systemService.diskTotal - systemService.diskFree))/\(formatGB(systemService.diskTotal))G"
            )
        }
        .notchCard()
        .padding(.vertical, 2)
    }

    private func statusChip(systemImage: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10))
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(NotchTheme.textSecondary)
        .frame(maxWidth: .infinity)
    }

    private var isCharging: Bool { systemService.isCharging }

    private var batteryIcon: String {
        switch systemService.batteryLevel {
        case 90...: return "battery.100"
        case 60 ..< 90: return "battery.75"
        case 35 ..< 60: return "battery.50"
        case 10 ..< 35: return "battery.25"
        default: return "battery.0"
        }
    }

    private func loadColor(_ usage: Double) -> Color {
        if usage > 80 { return .red }
        if usage > 50 { return .yellow }
        return NotchTheme.textPrimary
    }

    // MARK: - Helpers

    private func formatGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.0f", gb)
    }

    private func formatMemory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1fG", mb / 1024)
        }
        return String(format: "%.0fM", mb)
    }

    private func formatSpeed(_ bytesPerSec: Double) -> String {
        if bytesPerSec < 1024 {
            return "\(Int(bytesPerSec))B"
        } else if bytesPerSec < 1_048_576 {
            return String(format: "%.1fK", bytesPerSec / 1024)
        } else if bytesPerSec < 1_073_741_824 {
            return String(format: "%.1fM", bytesPerSec / 1_048_576)
        } else {
            return String(format: "%.1fG", bytesPerSec / 1_073_741_824)
        }
    }
}

// MARK: - Card

/// One metric card: icon+title header, bold value line, sparkline graph.
/// Fixed section heights keep the three cards' baselines aligned even when
/// values change width.
private struct SystemStatCard<Graph: View>: View {
    let icon: String
    let title: String
    let value: String
    let valueColor: Color
    var valueFont: Font = .system(size: 13, weight: .semibold, design: .monospaced)
    @ViewBuilder let graph: Graph

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(NotchTheme.textTertiary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchTheme.textTertiary)
                Spacer(minLength: 0)
            }

            Text(value)
                .font(valueFont)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 16, alignment: .center)

            graph
                .frame(height: 34)
                .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(NotchTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(NotchTheme.stroke, lineWidth: 0.6)
                )
        )
    }
}

// MARK: - Graphs

/// Sparkline: polyline over the sample history plus a gradient fill down to
/// the baseline. Normalized to the window max so small movements stay
/// readable; a flat/empty history renders as a quiet baseline.
private struct MiniGraph: View {
    let data: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let maxValue = max(data.max() ?? 0, 0.0001)
            let points = data.enumerated().map { index, value -> CGPoint in
                let x = data.count > 1
                    ? geometry.size.width * CGFloat(index) / CGFloat(data.count - 1)
                    : geometry.size.width
                let y = geometry.size.height * (1 - CGFloat(min(value / maxValue, 1)))
                return CGPoint(x: x, y: y)
            }

            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: geometry.size.height))
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.30), color.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
    }
}

/// Split sparkline for paired metrics (download above the center line,
/// upload below), sharing one scale so the two halves are comparable.
private struct DualQuadrantGraph: View {
    let topData: [Double]
    let bottomData: [Double]
    let topColor: Color
    let bottomColor: Color

    var body: some View {
        GeometryReader { geometry in
            let maxValue = max((topData + bottomData).max() ?? 0, 0.0001)
            let centerY = geometry.size.height / 2

            ZStack {
                Rectangle()
                    .fill(NotchTheme.stroke)
                    .frame(height: 0.6)
                    .frame(maxHeight: .infinity)
                    .frame(height: 0.6, alignment: .center)

                quadrant(data: topData, color: topColor, isTop: true, geometry: geometry, centerY: centerY, maxValue: maxValue)
                quadrant(data: bottomData, color: bottomColor, isTop: false, geometry: geometry, centerY: centerY, maxValue: maxValue)
            }
        }
    }

    private func quadrant(
        data: [Double],
        color: Color,
        isTop: Bool,
        geometry: GeometryProxy,
        centerY: CGFloat,
        maxValue: Double
    ) -> some View {
        let points = data.enumerated().map { index, value -> CGPoint in
            let x = data.count > 1
                ? geometry.size.width * CGFloat(index) / CGFloat(data.count - 1)
                : geometry.size.width
            let magnitude = centerY * CGFloat(min(value / maxValue, 1))
            let y = isTop ? centerY - magnitude : centerY + magnitude
            return CGPoint(x: x, y: y)
        }

        return ZStack {
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            Path { path in
                guard let first = points.first else { return }
                path.move(to: CGPoint(x: first.x, y: centerY))
                path.move(to: first)
                points.dropFirst().forEach { path.addLine(to: $0) }
                path.addLine(to: CGPoint(x: geometry.size.width, y: centerY))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: isTop
                        ? [color.opacity(0.30), color.opacity(0.06)]
                        : [color.opacity(0.06), color.opacity(0.30)],
                    startPoint: isTop ? .top : .center,
                    endPoint: isTop ? .center : .bottom
                )
            )
        }
    }
}
