---
summary: 'macOS TCC 七态完整状态机：Swift 枚举五 case，in_effect / denied_sticky 为真实瞬态；三类权限（Screen Recording / Accessibility / AppleEvents）生效时机各异。'
read_when:
  - '接入屏幕录制、辅助功能或 AppleEvents 权限，需要建模完整的状态机'
  - '调试"用户已在系统设置勾选但 app 感知不到"或"拒绝后 prompt 不再弹"'
  - '实现 1 s 轮询 + ReplayD 分歧检测 + 重启提示'
sources: ['P05', 'N §11']
last_verified:
  peekaboo: '2a523301b0addfe2ce61959d0152e28435491a74'
  nemonotch: 'fe4e9e5'
---

# TCC 权限七态状态机

## TL;DR

macOS TCC 在逻辑上有七个状态，但 Swift 枚举只需五个 `case`：`unknown / prompted / granted / denied / revoked`。`in_effect` 和 `denied_sticky` 是两个**真实的瞬态**（transient states），体现在检测逻辑和 UX 分支里，而非独立 `case`——这是裁决的核心：

- **`in_effect`**（授权后有生效延迟）：TCC 数据库已写入 `granted`，但进程内缓存尚未刷新。仅 Screen Recording 存在此瞬态（ReplayD 进程级缓存）。检测方法：`SCShareableContent` 探针 ✓ 而 `CGPreflightScreenCaptureAccess()` 仍返回 `false`。处理：提示用户**重启进程**，不要静默重试。
- **`denied_sticky`**（拒绝黏性）：用户拒绝后，`AXIsProcessTrustedWithOptions(prompt: true)` 不再弹窗，只能通过 `tccutil reset` 或手动在系统设置重新勾选恢复。Accessibility 和（首次拒绝后的）Screen Recording 均有此行为。

三类权限生效时机对比：

| 权限 | 查询 API | 热生效 | 粒度 | `in_effect` 风险 |
|------|---------|--------|------|-----------------|
| Screen Recording | `CGPreflightScreenCaptureAccess()` | **否**（须重启进程） | 进程/bundle | **高**（ReplayD 缓存） |
| Accessibility | `AXIsProcessTrusted()` | **是**（每次调用查实时状态） | 进程/bundle | 无 |
| AppleEvents | `AEDeterminePermissionToAutomateTarget` | **是**（per-app prompt 后立即生效） | 调用方 × 目标 app | 无 |

---

## 可复用模式

### 七态完整图

```
        tccutil reset / 首次运行
               │
               ▼
           unknown  ──── request() ────►  prompted
                                              │
                              ┌───────────────┴───────────────┐
                              ▼ user granted                  ▼ user denied
                          granted                          denied
                              │                               │
                              │                               │  (首次拒绝后 prompt 不再弹)
                              │ [Screen Recording only]       ▼
                              │ TCC 数据库已更新          denied_sticky ──────────────────┐
                              │ 但进程缓存未刷                                             │
                              ▼                                                           │
                         in_effect ──── 用户重启进程 ────► granted（进程内可用）           │
                              │                                                           │
                              │ (AX / AppleEvents 无此瞬态，直接热生效)                   │
                              ▼                                                           │
                          [正常使用]                                                      │
                              │                                                           │
                              │ 用户在系统设置取消                                         │
                              ▼                                                           │
                          revoked ──────────────────── tccutil reset ──────────────────►│
                                                                                         │
                              ◄─────────────────────────────────────────────────────────┘
```

**说明**：
- `in_effect` 和 `denied_sticky` 在图中显式标注，但 Swift 枚举不需要独立 case——`in_effect` 在轮询代码里表现为 `screenRecordingNeedsRestart = true` 标志，`denied_sticky` 表现为"prompt 后状态仍为 `denied`"的分支。
- `revoked` 是从 `granted` 离开、通过系统设置手动取消的边。用 `prevState == .granted && currentState == .denied` 检测。

### Swift 枚举（五 case，覆盖七态）

```swift
/// macOS TCC 权限的五 case 状态枚举。
/// in_effect 和 denied_sticky 是运行时用 needsRestart 标志 / prompt 行为捕获的瞬态，
/// 不需要独立 case——保持枚举简单，避免 UI 逻辑碎片化。
public enum PermissionState: String, Sendable, CaseIterable {
    case unknown    // 从未查询；初始状态
    case prompted   // 已弹 prompt，等待用户回应
    case granted    // TCC 数据库已授权（Screen Recording 可能仍需重启进程）
    case denied     // 用户拒绝；sticky，后续 prompt 不再弹（AX）
    case revoked    // 曾经授权，现已被取消（系统设置反勾）
}
```

来源：`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/System/ObservablePermissionsService.swift:29`

### Pattern 1 · 查询 → 引导 → 1 s 轮询（基础流）

```swift
// 1. 查询（同步，AX 每次查实时状态，ScreenRec 读进程缓存）
let axOK     = AXIsProcessTrusted()
let screenOK = CGPreflightScreenCaptureAccess()

// 2. 引导：打开系统设置深链
NSWorkspace.shared.open(URL(string:
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)

// 3. 1 s 轮询，检测跳变
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    Task { @MainActor in
        service.checkPermissions()
        // AX: denied → granted → 立即清除错误提示，重试失败操作
        // ScreenRec: denied → granted 但 needsRestart = true → 提示重启
    }
}
```

来源：`ObservablePermissionsService.swift:496-510`；NemoNotch `NotificationService.swift:14, 84`

### Pattern 2 · ReplayD 缓存分歧检测（Screen Recording 专用）

`in_effect` 瞬态的检测：`SCShareableContent` 探针成功 → TCC 数据库已授权，但 `CGPreflightScreenCaptureAccess()` 仍 false → **提示重启，不静默重试**。

```swift
@available(macOS 12.3, *)
func detectReplayDStaleness() async -> Bool {
    guard !CGPreflightScreenCaptureAccess() else { return false }
    do {
        _ = try await SCShareableContent.current   // 命中 TCC 真实状态
        return true  // 数据库已授权，进程缓存未刷 → in_effect 瞬态
    } catch {
        return false // 真实拒绝
    }
}
```

来源：`ScreenCapturePermissionGate.swift:9-39`；Peekaboo `PermissionsService.swift:28`

### Pattern 3 · AppleEvents per-target 矩阵

TCC 为 AppleEvents 维护"调用方 bundle ID × 目标 app bundle ID"二维表。每个目标 app 需独立授权；对 System Events 已授权不等于对 Finder 已授权。

```swift
// 查询（askUser: false = 只查，不弹）
func checkAppleEvents(targetBundleID: String) -> PermissionState {
    guard var desc = makeAETargetDesc(bundleID: targetBundleID) else { return .denied }
    defer { AEDisposeDesc(&desc) }
    let status = AEDeterminePermissionToAutomateTarget(
        &desc,
        AEEventClass(0x636F_7265),  // 'core'
        AEEventID(0x6765_7464),     // 'getd'
        false
    )
    switch status {
    case noErr:           return .granted
    case OSStatus(-1743): return .denied   // errAEEventNotPermitted
    default:              return .unknown
    }
}
```

来源：`PermissionsService.swift:167-200`；NemoNotch `MediaBridge.swift:142-163`

### Pattern 4 · revoked 检测

```swift
// 在每次 refresh() 中比对前一次状态
let prev = screenRecordingState
screenRecordingState = core.checkScreenRecording()
if prev == .granted, screenRecordingState == .denied {
    screenRecordingState = .revoked  // 曾授权，现被取消
}
```

来源：`ObservablePermissionsService.swift:516-542`

---

## 锚点（file:line）

| 符号 | 文件:行 | 说明 |
|------|---------|------|
| `PermissionState` 枚举 | `PeekabooAutomationKit/Services/System/ObservablePermissionsService.swift:29` | 五 case 定义 |
| `checkScreenRecording()` | `PeekabooAutomationKit/Services/System/PermissionsService.swift:28` | CGPreflight 注释说明 CLI 缓存问题 |
| `ScreenCapturePermissionGate` | `PeekabooAutomationKit/Services/Capture/ScreenCapturePermissionGate.swift:11` | SCShareableContent 探针 |
| `ObservablePermissionsService.startMonitoring` | `PeekabooAutomationKit/Services/System/ObservablePermissionsService.swift:496` | 1 s Timer 驱动 |
| `Permissions.swift` UI 层轮询 | `Apps/Mac/Peekaboo/Core/Permissions.swift:120` | 0.5 s 防抖，可选权限 10 s 节流 |
| NemoNotch AX 轮询 | `NemoNotch/Services/NotificationService.swift:14, 84` | 2 s Timer，`isAXTrusted` |
| NemoNotch AppleEvents 探针 | `NemoNotch/Services/MediaBridge.swift:142-163` | `hasAutomationAccess` benign-read 模式 |

---

## Pitfalls

### 陷阱 1 · Screen Recording 授权后不重启不生效（`in_effect` 瞬态）

**症状**：用户在系统设置勾选后截图仍空白，`CGPreflightScreenCaptureAccess()` 仍 false。
**原因**：ReplayD 进程级缓存未刷，TCC 数据库已授权但进程未感知。
**处理**：用 Pattern 2 检测分歧 → 提示"请重启"，不要静默重试 `CGWindowListCreate`。

### 陷阱 2 · AX 首次拒绝后 prompt 永久沉默（`denied_sticky`）

**症状**：`AXIsProcessTrustedWithOptions(prompt: true)` 不弹窗，什么都没有发生。
**原因**：TCC 拒绝是粘性状态，系统不重新触发 prompt。
**处理**：检测 `denied` 后主动显示"请在系统设置 → 辅助功能开启"+ deeplink 按钮；开发阶段用 `tccutil reset Accessibility <bundleID>` 重置。

### 陷阱 3 · AppleEvents 没有同步查询 API

**症状**：每次调用前需要先做一次 benign read，才能知道是否有权限。
**原因**：`AEDeterminePermissionToAutomateTarget(askUser: false)` 是目前最接近"只查"的方式，但仍有副作用（target 未运行时返回 `procNotFound`）。
**处理**：用 `errAEEventNotPermitted`（-1743）作为拒绝信号；用 `SBApplicationDelegate.eventDidFail` 作为异步拒绝信号（NemoNotch `MediaBridge.swift:35-43`）。

### 陷阱 4 · `tccutil reset` 对 MAS 签名 app 无效

用 `codesign -d -r - /path/App.app` 获取真实 signing identifier 再调用 `tccutil reset`。

---

## 落地 checklist

- [ ] 在 `project.pbxproj` 添加三个 `INFOPLIST_KEY_NS*UsageDescription`（见 [infoplist-pitfall.md](infoplist-pitfall.md)）
- [ ] Swift 枚举用五 case；`in_effect` 用 `needsRestart: Bool` 标志表达，`denied_sticky` 用"prompt 后仍为 denied"分支处理
- [ ] Screen Recording：查询走 `CGPreflightScreenCaptureAccess()`；同时跑 `detectReplayDStaleness()` → `needsRestart = true` 时显示重启提示
- [ ] Accessibility：1–2 s `Timer` 持续调用 `AXIsProcessTrusted()`（不是 `WithOptions`），检测到 `granted` 后清除错误提示并重试
- [ ] AppleEvents：每个目标 app 独立请求；`-1743` 是唯一可靠的同步拒绝信号
- [ ] `revoked` 检测：每次轮询比对 `prev == .granted && current == .denied`
- [ ] 开发调试：`tccutil reset ScreenCapture/Accessibility/AppleEvents <bundleID>`

---

## 延伸阅读

- [permission-card-ux.md](permission-card-ux.md) — NemoNotch never-auto-prompt 模式与 PermissionCard Grant 按钮
- [infoplist-pitfall.md](infoplist-pitfall.md) — GENERATE_INFOPLIST_FILE 陷阱与 NSAppleEventsUsageDescription 缺失
- [../accessibility/](../accessibility/) — AX 权限前置与 AXorcist
- [../screen-capture/](../screen-capture/) — Screen Recording 权限依赖
- [../keychain/](../keychain/) — Keychain ACL 的 needsAuthorization 模式（与本文 TCC 模式平行）
