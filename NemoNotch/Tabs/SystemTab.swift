import SwiftUI

struct SystemTab: View {
    @Environment(SystemService.self) var systemService

    private var sortedProcesses: [ProcessEntry] {
        switch systemService.processSortMode {
        case .cpu: systemService.topProcessesByCPU
        case .memory: systemService.topProcessesByMemory
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("排序", selection: Bindable(systemService).processSortMode) {
                Text("CPU").tag(ProcessSortMode.cpu)
                Text("内存").tag(ProcessSortMode.memory)
            }
            .pickerStyle(.segmented)

            ForEach(sortedProcesses) { process in
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

            Text(processValue(process))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(processColor(process))
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

    private func processValue(_ process: ProcessEntry) -> String {
        switch systemService.processSortMode {
        case .cpu: String(format: "%.1f%%", process.cpuUsage)
        case .memory: formatMemory(process.memoryUsed)
        }
    }

    private func processColor(_ process: ProcessEntry) -> Color {
        switch systemService.processSortMode {
        case .cpu:
            if process.cpuUsage > 80 { return .red }
            if process.cpuUsage > 50 { return .yellow }
            return NotchTheme.textPrimary
        case .memory:
            return NotchTheme.textPrimary
        }
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
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}
