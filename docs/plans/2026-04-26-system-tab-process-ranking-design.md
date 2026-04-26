# System Tab: Process Resource Ranking

## Problem

The System tab is registered but not connected (NotchView returns `EmptyView()`). The existing SystemService monitors system-level CPU/memory/battery/disk but lacks per-process visibility, making it hard to quickly identify which apps are consuming resources.

## Design

Replace the disconnected System tab with a **Top 5 process resource ranking** view, defaulting to CPU sort with a toggle to switch to memory sort.

### Data Model

```swift
enum ProcessSortMode {
    case cpu
    case memory
}

struct ProcessInfo: Identifiable {
    let id: Int32              // pid
    let name: String           // process name
    let displayName: String    // friendly name from NSRunningApplication
    let icon: NSImage?         // app icon
    let cpuUsage: Double       // 0-100%
    let memoryUsed: UInt64     // bytes
}
```

### Service Layer (SystemService.swift)

**New properties:**
- `topProcessesByCPU: [ProcessInfo]` — CPU Top 5
- `topProcessesByMemory: [ProcessInfo]` — Memory Top 5
- `processSortMode: ProcessSortMode` — current sort, defaults to `.cpu`

**New method: `updateProcesses()`**
1. `proc_listpids()` — get all PIDs via libproc kernel API
2. `proc_pidinfo()` with `PROC_PIDTASKINFO` — read CPU ticks and memory for each PID
3. CPU delta calculation: `(current_ticks - previous_ticks) / elapsed_time`
4. `NSRunningApplication` — map PID to app icon and display name
5. Sort and take Top 5 for both CPU and memory
6. Called from existing 2-second timer in `update()`

Existing system-level metrics (total CPU, memory, battery, disk) are preserved.

### UI (SystemTab.swift)

**Layout (top to bottom):**
1. **Sort toggle** — `Picker` with segmented style: CPU / Memory
2. **Top 5 list** — 5 rows, each row:
   - Left: app icon (20x20, rounded)
   - Center: app name (truncated)
   - Right: value label (CPU mode: `12.3%`, Memory mode: `234 MB`)
3. **Footer summary** — one line: `CPU 34% · RAM 8.2/16GB · Battery 87%`

**Visual style:**
- NotchTheme colors, consistent with other tabs
- CPU percentage color: white (normal), yellow (>50%), red (>80%)
- Compact spacing to fit notch height

**Interaction:** Display only, no click actions. YAGNI — consider Activity Monitor jump later if needed.

### Implementation Approach

Use `libproc.h` kernel APIs (`proc_listpids`, `proc_pidinfo`) for process data, supplemented by `NSRunningApplication` for icons and friendly names. This is the standard approach used by `eul` and other macOS system monitors.

Reference: `/Users/gaozimeng/Learn/macOS/eul` has working libproc process listing code.

### Files to Change

| File | Action | Description |
|------|--------|-------------|
| `Models/ProcessInfo.swift` | Create | ProcessInfo model + ProcessSortMode enum |
| `Services/SystemService.swift` | Modify | Add process listing via libproc + NSRunningApplication |
| `Tabs/SystemTab.swift` | Rewrite | Ranking list UI replacing existing overview |
| `NemoNotchApp.swift` | Modify | Instantiate SystemService, inject into environment |
| `Notch/NotchView.swift` | Modify | `case .system` → `SystemTab()` instead of `EmptyView()` |

### Files NOT Changed

- `Models/Tab.swift` — `.system` already registered
- Other tabs/services — no impact
