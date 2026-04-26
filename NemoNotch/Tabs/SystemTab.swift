import SwiftUI

struct SystemTab: View {
    @Environment(SystemService.self) var systemService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(systemService.topProcessesByCPU) { process in
                processRow(process)
            }

            summaryFooter
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 12)
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
                .foregroundStyle(cpuColor(process.cpuUsage))
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

    private func cpuColor(_ usage: Double) -> Color {
        if usage > 80 { return .red }
        if usage > 50 { return .yellow }
        return NotchTheme.textPrimary
    }

    // MARK: - Summary Footer

    private var summaryFooter: some View {
        HStack(spacing: 6) {
            Text("CPU \(Int(systemService.cpuUsage))%")
            Text("·")
            Text("RAM \(formatGB(systemService.memoryUsed))/\(formatGB(systemService.memoryTotal))")
            Text("·")
            Text("\(systemService.batteryLevel)%")
        }
        .font(.system(size: 10))
        .foregroundStyle(NotchTheme.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
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
}
