import Foundation
import IOKit.ps

@Observable
final class SystemService {
    var cpuUsage: Double = 0
    var cpuHistory: [Double] = []
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var batteryLevel: Int = 0
    var isCharging: Bool = false
    var timeRemaining: Int = -1
    var diskFree: UInt64 = 0
    var diskTotal: UInt64 = 0

    private var timer: Timer?
    private let maxHistory = 60

    // For CPU calculation (need to track previous values)
    private var prevTotal: Double = 0
    private var prevIdle: Double = 0

    init() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.update()
        }
    }

    deinit { timer?.invalidate() }

    func update() {
        updateCPU()
        updateMemory()
        updateBattery()
        updateDisk()
    }

    private func updateCPU() {
        var numCPU: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = withUnsafeMutablePointer(to: &numCPU) { numCPUPtr in
            host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, numCPUPtr, &cpuInfo, &numCPUInfo)
        }

        guard result == KERN_SUCCESS, let cpuInfo = cpuInfo else { return }

        var total: Double = 0
        var idle: Double = 0
        let numCores = Int(numCPU)
        for i in 0..<numCores {
            let user = Double(cpuInfo[i * CPU_STATE_MAX + CPU_STATE_USER])
            let system = Double(cpuInfo[i * CPU_STATE_MAX + CPU_STATE_SYSTEM])
            let nice = Double(cpuInfo[i * CPU_STATE_MAX + CPU_STATE_NICE])
            let idleVal = Double(cpuInfo[i * CPU_STATE_MAX + CPU_STATE_IDLE])
            total += user + system + nice + idleVal
            idle += idleVal
        }

        let diffTotal = total - prevTotal
        let diffIdle = idle - prevIdle
        if diffTotal > 0 {
            cpuUsage = ((diffTotal - diffIdle) / diffTotal) * 100
        }

        prevTotal = total
        prevIdle = idle

        cpuHistory.append(cpuUsage)
        if cpuHistory.count > maxHistory { cpuHistory.removeFirst() }

        // Clean up
        let size = numCPUInfo * MemoryLayout<integer_t>.size
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(size))
    }

    private func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            host_statistics64(mach_host_self(), HOST_VM_INFO64, ptr, &count)
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)
        memoryTotal = UInt64(ProcessInfo.processInfo.physicalMemory)
        memoryUsed = (UInt64(stats.active_count) + UInt64(stats.wire_count)) * pageSize
    }

    private func updateBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeRetainedValue() as? [String: Any] else { continue }
            if let capacity = info[kIOPSCurrentCapacityKey] as? Int {
                batteryLevel = capacity
            }
            if let charging = info[kIOPSIsChargingKey] as? Bool {
                isCharging = charging
            }
            if let time = info[kIOPSTimeToEmptyKey] as? Int {
                timeRemaining = time
            }
        }
    }

    private func updateDisk() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        diskTotal = UInt64(values?.volumeTotalCapacity ?? 0)
        diskFree = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
