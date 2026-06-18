---
summary: '用私有 DisplayServices 轮询亮度（无中断机制，须自适应 cadence）；用 IOPS 快照或 runloop 推送读取电量'
read_when:
  - '实现音量 / 亮度 / 电量 HUD overlay'
  - '接入 DisplayServices 私有 API 读取屏幕亮度'
  - '需要电量变化推送通知而非定时轮询'
sources: ['NemoNotch §8']
last_verified: { nemonotch: 'fe4e9e5' }
---

# 亮度 / 电量采样

## TL;DR

| 子系统 | API | 模式 |
|---|---|---|
| 亮度 | `DisplayServicesGetBrightness()` 私有 API（`dlsym` 加载） | 轮询；无中断，须自适应 cadence（空闲 1 s → 变化中 0.1 s） |
| 电量（快照） | `IOPSCopyPowerSourcesInfo` + `IOPSCopyPowerSourcesList` | Create / Get 规则严格区分，不能混用 |
| 电量（推送） | `IOPSNotificationCreateRunLoopSource` | C 回调，无 `@MainActor` 推断，需显式 hop 到主线程 |

`DisplayServicesGetBrightness` 的 **dlopen / dlsym 加载**方式见 [`../private-api/`](../private-api/)（§4.1）；本篇只覆盖用法和 polling cadence。

## 可复用模式

### 亮度：自适应轮询循环

```swift
private func readBrightness() {
    guard let brightness = getBrightness() else { return }  // getBrightness 通过 dlsym 加载

    if lastBrightness >= 0, abs(brightness - lastBrightness) > 0.01 {
        // 检测到变化 → 触发 HUD，切换为高频（0.1 s）
        showHUD(.brightness, value: brightness)
        brightnessTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.readBrightness() }
        }
        brightnessTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    } else if lastBrightness >= 0,
              let timer = brightnessTimer, timer.timeInterval < 1.0 {
        // 稳定后降回低频（1.0 s）
        timer.invalidate()
        // 重新创建 1.0s timer（省略，与上面对称）
    }
    lastBrightness = brightness
}
```

关键：`RunLoop.main.add(timer, forMode: .common)` 使 timer 在 `.tracking` 模式（拖动 slider 期间）也继续触发。

### 电量：IOPS 快照（一次性读取）

```swift
guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
// ↑ CopyPowerSourcesInfo = Create Rule → takeRetainedValue()

guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }

for source in sources {
    guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
    else { continue }
    // ↑ GetPowerSourceDescription = Get Rule → takeUnretainedValue()

    if let capacity = info[kIOPSCurrentCapacityKey] as? Int { batteryLevel = capacity }
    if let charging = info[kIOPSIsChargingKey] as? Bool     { isCharging = charging }
    if let time = info[kIOPSTimeToEmptyKey] as? Int         { timeRemaining = time }
}
```

### 电量：IOPS 推送（RunLoop source）

```swift
// 在服务 init 里调用一次
private func setupBatteryMonitoring() {
    let context = Unmanaged.passUnretained(self).toOpaque()
    guard let unmanagedSource = IOPSNotificationCreateRunLoopSource(
        { context in
            guard let context else { return }
            let service = Unmanaged<HUDService>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { service.readBattery() }  // 必须 hop 到主线程
        },
        context
    ) else { return }
    let source = unmanagedSource.takeRetainedValue() as CFRunLoopSource
    batteryRunLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
}
```

保存 `batteryRunLoopSource` 以便在 `deinit` 时 `CFRunLoopRemoveSource`；否则 RunLoop 持有 source，服务永远不会 deinit。

## 锚点（file:line）

| 子系统 | 文件 | 行号 / 函数 |
|---|---|---|
| 亮度轮询 | `NemoNotch/Services/HUDService.swift:186-216` | `readBrightness()` |
| 电量快照 | `NemoNotch/Services/SystemService.swift:138-155` | `updateBattery()` |
| 电量推送 | `NemoNotch/Services/HUDService.swift:220-236` | `setupBatteryMonitoring()` |
| DisplayServices dlopen | `NemoNotch/Services/HUDService.swift` | §4.1 参考 |

参考项目：*MonitorControl* — `DisplayServicesGetBrightness()` 私有 API 的原始发现者，`dlopen` 配方直接来源（§8.10）。

## Pitfalls

### 亮度
- **没有中断机制。** `DisplayServices` 不发通知，只能轮询。持续 0.1 s 轮询（idle MacBook）会引起可观的 wakeup 功耗，必须在稳定后退回 1.0 s。
- **dlsym 加载失败时 `getBrightness()` 返回 nil。** 上层逻辑要能处理 nil（直接 `guard … else { return }`），不要假设 API 一定存在。
- **Timer 若不加 `.common` mode** 在 UI 交互（ScrollView 拖动）期间会被暂停，HUD 更新中断。

### 电量（快照）
- **Create / Get 混用导致泄漏或崩溃：**
  - `IOPSCopyPowerSourcesInfo` → `takeRetainedValue()`（Create Rule）
  - `IOPSGetPowerSourceDescription` → `takeUnretainedValue()`（Get Rule）
- **无电池的 Mac（Mac mini、Mac Studio）`sources` 为空数组。** 循环体永远不执行；UI 状态应保持"未初始化"，而不是"电量为 0"。
- **`kIOPSTimeToEmptyKey` 在充电时可能缺失或为 -1。** 必须 optional-bind，不能强转。

### 电量（推送 RunLoop）
- **C 回调，无 `@MainActor` 推断。** 即使服务声明了 `@MainActor`，回调也在 RunLoop 线程执行；必须 `DispatchQueue.main.async { … }` 才能安全 touch state。Swift 6 会把缺少 hop 标为 data-race 错误。
- **`Unmanaged.passUnretained` / `fromOpaque().takeUnretainedValue()` 必须匹配。** 用 `passRetained` 配 `takeRetainedValue` 或 `passUnretained` 配 `takeUnretainedValue`；混用会崩溃或泄漏。
- **必须保存 source 引用并在 deinit 时 `CFRunLoopRemoveSource`，** 否则 RunLoop 持有 source 导致服务无法释放。

## 落地 checklist

- [ ] `DisplayServicesGetBrightness` 通过 `dlopen` / `dlsym` 加载（见 `../private-api/`），失败时降级
- [ ] 亮度 timer：检测到变化切换为 0.1 s，稳定后退回 1.0 s
- [ ] 亮度 timer：用 `RunLoop.main.add(timer, forMode: .common)` 注册
- [ ] 电量快照：`CopyPowerSourcesInfo` → `takeRetainedValue`，`GetPowerSourceDescription` → `takeUnretainedValue`
- [ ] 电量快照：sources 为空时 UI 显示"N/A"而非"0%"
- [ ] 电量推送：回调内 `DispatchQueue.main.async` hop 到主线程
- [ ] 电量推送：`Unmanaged.passUnretained` 与 `takeUnretainedValue` 配对使用
- [ ] 电量推送：`batteryRunLoopSource` 保存为属性，`deinit` 时移除

## 延伸阅读

- [`../private-api/`](../private-api/) — `dlopen` + `dlsym` 加载私有框架的完整模式（§4.1，DisplayServices 即此模式）
- [`cpu-memory-disk.md`](cpu-memory-disk.md) — 同文件 `SystemService.swift` 中的其余采样子系统
