@preconcurrency import Foundation
import AppKit
import IOKit.ps

@MainActor
@Observable
final class SystemService {
    // System-level metrics
    var cpuUsage: Double = 0
    var cpuHistory: [Double] = []
    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var batteryLevel: Int = 0
    var isCharging: Bool = false
    var timeRemaining: Int = -1
    var diskFree: UInt64 = 0
    var diskTotal: UInt64 = 0

    // Process-level metrics
    var topProcessesByCPU: [ProcessEntry] = []
    var topProcessesByMemory: [ProcessEntry] = []

    private var timer: Timer?
    private let maxHistory = 60

    // CPU delta tracking (system-level)
    private var prevTotal: Double = 0
    private var prevIdle: Double = 0

    // Per-process CPU delta tracking
    private var prevProcessTicks: [Int32: UInt64] = [:]
    private var isFirstProcessUpdate = true
    private var lastUpdateTime: Date = .now

    init() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.update()
            }
        }
    }

    deinit { MainActor.assumeIsolated { timer?.invalidate() } }

    func update() {
        updateCPU()
        updateMemory()
        updateBattery()
        updateDisk()
        updateProcesses()
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
            let idx = Int32(i) * Int32(CPU_STATE_MAX)
            let user = Double(cpuInfo[Int(idx + Int32(CPU_STATE_USER))])
            let system = Double(cpuInfo[Int(idx + Int32(CPU_STATE_SYSTEM))])
            let nice = Double(cpuInfo[Int(idx + Int32(CPU_STATE_NICE))])
            let idleVal = Double(cpuInfo[Int(idx + Int32(CPU_STATE_IDLE))])
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

        let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
    }

    private func updateMemory() {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let statsPtr = UnsafeMutablePointer<vm_statistics64>.allocate(capacity: 1)
        defer { statsPtr.deallocate() }
        let result = host_statistics64(mach_host_self(), HOST_VM_INFO64, UnsafeMutableRawPointer(statsPtr).bindMemory(to: integer_t.self, capacity: Int(count)), &count)
        guard result == KERN_SUCCESS else { return }
        let stats = statsPtr.pointee

        let pageSize = UInt64(vm_kernel_page_size)
        memoryTotal = UInt64(ProcessInfo.processInfo.physicalMemory)
        memoryUsed = (UInt64(stats.active_count) + UInt64(stats.wire_count)) * pageSize
    }

    private func updateBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
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

    // MARK: - Process Listing (libproc)

    private func updateProcesses() {
        let now = Date.now
        let elapsed = now.timeIntervalSince(lastUpdateTime)
        lastUpdateTime = now
        guard elapsed > 0 else { return }

        let numCPUs = ProcessInfo.processInfo.processorCount

        // Get all PIDs
        let bufferCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferCount > 0 else { return }

        let pidCount = Int(bufferCount) / MemoryLayout<Int32>.size
        var pids = [Int32](repeating: 0, count: pidCount)
        let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(bufferCount))
        guard actualSize > 0 else { return }

        let actualCount = Int(actualSize) / MemoryLayout<Int32>.size
        let runningApps = NSWorkspace.shared.runningApplications
        var appByPID: [Int32: NSRunningApplication] = [:]
        for app in runningApps {
            appByPID[app.processIdentifier] = app
        }

        var newProcessTicks: [Int32: UInt64] = [:]
        var processes: [ProcessEntry] = []

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }

            var taskInfo = proc_taskinfo()
            let infoSize = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
            guard infoSize > 0 else { continue }

            // CPU: total ticks = user + system
            let totalTicks = UInt64(taskInfo.pti_total_user) + UInt64(taskInfo.pti_total_system)
            let prevTicks = prevProcessTicks[pid] ?? 0
            let tickDelta = totalTicks > prevTicks ? totalTicks - prevTicks : 0
            // Convert to percentage: ticks are in nanoseconds, elapsed in seconds
            let cpuPercent = Double(tickDelta) / (elapsed * Double(numCPUs) * 1_000_000_000) * 100

            newProcessTicks[pid] = totalTicks

            let memoryBytes = UInt64(taskInfo.pti_resident_size)

            // Get friendly name and icon
            let app = appByPID[pid]
            let fallbackName = extractName(from: pid)
            let displayName = app?.localizedName ?? fallbackName

            let process = ProcessEntry(
                id: pid,
                displayName: displayName.isEmpty ? fallbackName : displayName,
                icon: app?.icon,
                cpuUsage: min(cpuPercent, 100),
                memoryUsed: memoryBytes
            )
            processes.append(process)
        }

        // On first call, just seed the tick baseline — skip percentage calculation
        if isFirstProcessUpdate {
            prevProcessTicks = newProcessTicks
            isFirstProcessUpdate = false
            return
        }

        prevProcessTicks = newProcessTicks

        // Filter out NemoNotch itself and kernel_task
        let ownPID = ProcessInfo.processInfo.processIdentifier
        processes = processes.filter { $0.id != ownPID && $0.id != 0 }

        topProcessesByCPU = processes.sorted { $0.cpuUsage > $1.cpuUsage }.prefix(5).map { $0 }
        topProcessesByMemory = processes.sorted { $0.memoryUsed > $1.memoryUsed }.prefix(5).map { $0 }
    }

    private func extractName(from pid: Int32) -> String {
        var path = [CChar](repeating: 0, count: 1024)
        let count = proc_pidpath(pid, &path, 1024)
        guard count > 0 else { return "PID \(pid)" }
        let utf8Bytes = path.prefix(Int(count)).map { UInt8(bitPattern: $0) }
        let raw = String(decoding: utf8Bytes, as: UTF8.self)
        let pathStr = raw.split(separator: "\0", maxSplits: 1).first.map(String.init) ?? raw
        let components = pathStr.split(separator: "/")
        if let appName = components.last(where: { $0.hasSuffix(".app") }) {
            return String(appName.dropLast(4))
        }
        return components.last.map(String.init) ?? "PID \(pid)"
    }
}
