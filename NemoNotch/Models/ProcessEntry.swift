import AppKit

enum ProcessSortMode: String, CaseIterable {
    case cpu
    case memory
}

struct ProcessEntry: Identifiable {
    let id: Int32 // pid
    let displayName: String
    let icon: NSImage?
    let cpuUsage: Double // 0-100%
    let memoryUsed: UInt64 // bytes
}
