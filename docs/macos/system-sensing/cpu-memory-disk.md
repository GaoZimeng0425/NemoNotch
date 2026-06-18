---
summary: '用 Mach host_processor_info / host_statistics64、libproc、getifaddrs、URLResourceValues 采样 CPU / 内存 / 进程 / 网络 / 磁盘'
read_when:
  - '实现系统监控面板 (CPU%、内存、磁盘、网络)'
  - '接入 SystemTab 或类似 eul 风格的 MenuBar 指标'
  - '排查 wired-memory 缓慢增长 / Instruments 看不出来的内核缓冲区泄漏'
sources: ['NemoNotch §8']
last_verified: { nemonotch: 'fe4e9e5' }
---

# CPU / 内存 / 进程 / 网络 / 磁盘采样

## TL;DR

五个子系统，每个用不同的框架，核心模式各异：

| 子系统 | API | 关键规则 |
|---|---|---|
| CPU | `host_processor_info` (Mach) | 每次必须 `vm_deallocate` 内核缓冲区 |
| 内存 | `host_statistics64` (Mach) | `count` 单位是 `integer_t` 槽位数，不是字节数 |
| 进程 | `libproc` 两次调用 | `proc_pidinfo` 返回 0 = 权限拒绝，跳过；时间单位是纳秒 |
| 网络 | `getifaddrs` (BSD) | 计数器是开机以来累计值，必须自己算 delta |
| 磁盘 | `URLResourceValues` | 用 `ForImportantUsage` key，不要用裸 `Available` key |

## 可复用模式

### CPU：per-core tick delta

```swift
var numCPU: natural_t = 0
var cpuInfo: processor_info_array_t?
var numCPUInfo: mach_msg_type_number_t = 0

let result = withUnsafeMutablePointer(to: &numCPU) { numCPUPtr in
    host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, numCPUPtr, &cpuInfo, &numCPUInfo)
}
guard result == KERN_SUCCESS, let cpuInfo else { return }

for i in 0 ..< Int(numCPU) {
    let idx = Int32(i) * Int32(CPU_STATE_MAX)
    let user   = Double(cpuInfo[Int(idx + Int32(CPU_STATE_USER))])
    let system = Double(cpuInfo[Int(idx + Int32(CPU_STATE_SYSTEM))])
    let nice   = Double(cpuInfo[Int(idx + Int32(CPU_STATE_NICE))])
    let idle   = Double(cpuInfo[Int(idx + Int32(CPU_STATE_IDLE))])
    // CPU% = (total_delta - idle_delta) / total_delta vs prevTotal/prevIdle
}

// 必须释放，否则泄漏内核缓冲区
let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.size)
vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
```

### 内存：vm_statistics64 页面计数

```swift
var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
let statsPtr = UnsafeMutablePointer<vm_statistics64>.allocate(capacity: 1)
defer { statsPtr.deallocate() }
let result = host_statistics64(
    mach_host_self(),
    HOST_VM_INFO64,
    UnsafeMutableRawPointer(statsPtr).bindMemory(to: integer_t.self, capacity: Int(count)),
    &count
)
guard result == KERN_SUCCESS else { return }
let pageSize = UInt64(vm_kernel_page_size)
// "已用内存" = active + wire；不含 inactive（macOS 投机保留）
memoryUsed = (UInt64(statsPtr.pointee.active_count) + UInt64(statsPtr.pointee.wire_count)) * pageSize
```

### 进程：libproc 两次调用

```swift
// 第一次：探测所需缓冲区大小
let bufferCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
guard bufferCount > 0 else { return }
var pids = [Int32](repeating: 0, count: Int(bufferCount) / MemoryLayout<Int32>.size)

// 第二次：填充
let actualSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(bufferCount))
guard actualSize > 0 else { return }

for i in 0 ..< Int(actualSize) / MemoryLayout<Int32>.size {
    let pid = pids[i]; guard pid > 0 else { continue }
    var taskInfo = proc_taskinfo()
    let infoSize = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))
    guard infoSize > 0 else { continue }  // 0 = 权限拒绝，跳过
    // pti_total_user / pti_total_system 单位：纳秒
    let totalNs = UInt64(taskInfo.pti_total_user) + UInt64(taskInfo.pti_total_system)
    // CPU% = deltaNs / (elapsed * processorCount * 1e9)
}
```

### 网络：getifaddrs delta 计算

```swift
var ifaddr: UnsafeMutablePointer<ifaddrs>?
guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return }
defer { freeifaddrs(ifaddr) }  // 必须释放，链表在堆上

var totalIBytes: UInt64 = 0
var totalOBytes: UInt64 = 0
var ptr = firstAddr
while true {
    let addr = ptr.pointee
    let name = String(cString: addr.ifa_name)
    if name != "lo0", addr.ifa_addr.pointee.sa_family == AF_LINK,
       let data = addr.ifa_data {
        let nd = data.assumingMemoryBound(to: if_data.self)
        totalIBytes += UInt64(nd.pointee.ifi_ibytes)
        totalOBytes += UInt64(nd.pointee.ifi_obytes)
    }
    guard let next = addr.ifa_next else { break }
    ptr = next
}
// downloadSpeed = (totalIBytes - lastTotalIBytes) / elapsed
// 首次采样跳过（无基准）；负 delta（计数器回绕）钳位为 0
```

### 磁盘：URLResourceValues（两行即可）

```swift
let home = FileManager.default.homeDirectoryForCurrentUser
let values = try? home.resourceValues(forKeys: [
    .volumeTotalCapacityKey,
    .volumeAvailableCapacityForImportantUsageKey,  // 不要用 volumeAvailableCapacityKey
])
diskTotal = UInt64(values?.volumeTotalCapacity ?? 0)
diskFree  = UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
```

## 锚点（file:line）

| 子系统 | 文件 | 行号 / 函数 |
|---|---|---|
| CPU | `NemoNotch/Services/SystemService.swift:80-118` | `updateCPU()` |
| 内存 | `NemoNotch/Services/SystemService.swift:120-136` | `updateMemory()` |
| 进程 | `NemoNotch/Services/SystemService.swift:219-270` | `updateProcesses()` |
| 网络 | `NemoNotch/Services/SystemService.swift:169-215` | `updateNetwork()` |
| 磁盘 | `NemoNotch/Services/SystemService.swift:157-165` | `updateDisk()` |

参考项目：*eul* — `host_processor_info` / `host_statistics64` 的直接前身，MenuBar 系统监控 UI 风格参考（§8.10）。

## Pitfalls

### CPU
- **必须 `vm_deallocate`。** 遗漏后内核缓冲区泄漏，Instruments 默认视图看不到，只能通过 `vm_stat` 观察 wired memory 缓慢攀升。
- **第一次采样无意义。** CPU% 是 delta（当前 - 前次），首次无基准，丢弃或显示 0。

### 内存
- **`count` 是 `integer_t` 槽位数，不是字节数。** 计算方式：`MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size`，传错单位会得到 `KERN_INVALID_ARGUMENT`（静默失败）。
- **"已用内存" = `active + wire`，不含 `inactive`。** macOS 把释放的页面投机保留为 inactive；把它计入会高估数十 GB。

### 进程
- **`proc_pidinfo` 返回 0 = 权限拒绝，不是"结构体填充了 0"。** 内核进程和其他用户进程都会返回 0；必须跳过，不能信任。
- **时间单位是纳秒，不是 jiffies。** 转为 CPU% 的公式：`deltaNs / (elapsedSec × processorCount × 1_000_000_000)`。

### 网络
- **计数器是开机以来累计值，不是每秒速率。** 首次采样无基准，丢弃。
- **计数器回绕（罕见，32-bit）会产生负 delta。** 钳位为 0，不要信任负值。
- **必须 `freeifaddrs`。** 链表在堆上，每次调用都会分配；`defer { freeifaddrs(ifaddr) }` 是最安全的写法。

### 磁盘
- **不要用 `.volumeAvailableCapacityKey`。** 它是原始文件系统可用量，不扣除可清除缓存，比"关于本机→存储"显示的值小很多（有时差数十 GB），会虚假告警。
- **不要用 `/` 作为 URL（Apple Silicon）。** `/` 是签名系统卷（SSV），只读，报告接近零的可用空间；使用 home directory URL 即可。

## 落地 checklist

- [ ] CPU：`vm_deallocate` 调用在函数末尾，每次采样都执行
- [ ] CPU：首次采样结果丢弃或显示占位值
- [ ] 内存：`count` 计算公式正确（槽位数，非字节数）
- [ ] 内存：used = `active_count + wire_count`，未加 `inactive_count`
- [ ] 进程：`proc_pidinfo` 返回值 ≤ 0 时跳过当前 PID
- [ ] 进程：CPU% 公式含 `processorCount × 1e9` 分母
- [ ] 网络：存储 `lastTotalIBytes` / `lastTotalOBytes` + 上次采样时间
- [ ] 网络：首次采样跳过；负 delta 钳位为 0；`defer freeifaddrs`
- [ ] 磁盘：key 为 `volumeAvailableCapacityForImportantUsageKey`
- [ ] 磁盘：URL 指向 home directory，不是 `/`

## 延伸阅读

- [`../private-api/`](../private-api/) — `dlopen` / `dlsym` 加载私有框架（DisplayServices 亮度 API 用到，见 `brightness-battery.md`）
- [`brightness-battery.md`](brightness-battery.md) — 同一 `SystemService` 里的亮度 / 电量采样
