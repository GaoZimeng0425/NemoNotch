---
summary: 'Model Screen Recording, Accessibility, and AppleEvents TCC permissions as a state machine, handling their differing restart requirements.'
read_when:
  - 'implementing permission request flows for screen capture or accessibility automation'
  - 'debugging permission state not updating after the user grants access in System Settings'
---

# 05 · 权限三态状态机

## TL;DR

macOS 将自动化敏感能力拆分为三类 TCC 权限：Screen Recording（截图/窗口枚举）、Accessibility（AX 操控/点击）、AppleEvents（per-app 脚本自动化）。三者共享同一套逻辑状态机——`notDetermined → prompted → authorized | denied`——但生效时机截然不同：Screen Recording **改后须重启进程**才生效，Accessibility **热生效**（无需重启），AppleEvents 则是**每个目标 app 单独弹 prompt**。正确建模这三类差异、用轮询而非一次性检查来感知状态变化，是稳健权限流的核心。sandboxed app 还需在 entitlements 中声明对应的使用意图，否则 TCC 根本不会弹确认对话框。

## Peekaboo 在哪里实现

- 模块：`PeekabooAutomationKit`（查询与请求）、`Apps/Mac/Peekaboo`（UI 监控）
- 关键文件：`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/System/PermissionsService.swift:28` — `checkScreenRecordingPermission()` 用 `CGPreflightScreenCaptureAccess` 做同步查询；注释说明 CLI 进程下该 API 不可靠
- 关键文件：`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/Capture/ScreenCapturePermissionGate.swift:16` — 当 preflight 返回 false 时自动 fallback 到 `SCShareableContent` 探针，规避 TCC code-signature 缓存问题
- 关键文件：`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/System/ObservablePermissionsService.swift:57` — 定义 `PermissionState` 三态枚举（`notDetermined / denied / authorized`）；`startMonitoring(interval:)` 以 1 s 定时器驱动轮询
- 关键文件：`Apps/Mac/Peekaboo/Core/Permissions.swift:185` — UI 层用 `AXIsProcessTrusted()` 直接查询 AX 状态；同文件第 120 行以 1 s `Timer` 循环调用 `checkRequiredPermissions()`
- 相关 docs：`docs/permissions.md`

## 设计动机（Why）

TCC 没有系统级通知推送——你无法订阅"用户刚在系统设置里勾了那个开关"的事件。早期实现依赖一次性检查：启动时查一次，失败就抛错，不再重试。结果是用户授权后必须手动重启才能继续。状态机 + 轮询解决了这个问题：UI 和 CLI 均以固定间隔重新查询，发现状态从 `denied` 变为 `authorized` 后自动恢复，无需用户干预。另一个教训是 Screen Recording 的 preflight API 对非 `.app` bundle（CLI 工具、重新编译后签名变化）会返回错误的 false，迫使我们引入 `SCShareableContent` 兜底探针。此外，AppleEvents 权限与其他两类不同，它不是进程级别的单一开关，而是"调用方 app × 目标 app"的矩阵——即使对 System Events 已授权，对 Finder 仍可能未授权，必须逐一处理。

## 核心模式（Pattern）

### 状态机

```
notDetermined ──request()──► prompted
                              │
              ┌───────────────┴───────────────┐
              ▼ granted                        ▼ denied
          authorized ◄──revoke/reset──── denied
              │                               │
              └──────── 重启进程 ─────────────┘
                (Screen Recording 需重启生效)
```

### 三类权限对照

| 维度 | Screen Recording | Accessibility | AppleEvents |
|------|-----------------|---------------|-------------|
| 查询 API | `CGPreflightScreenCaptureAccess()` | `AXIsProcessTrustedWithOptions` / `AXIsProcessTrusted()` | `AEDeterminePermissionToAutomateTarget` |
| 热生效 | **否**（需重启进程） | **是** | **是**（per-app prompt） |
| 粒度 | 进程/bundle | 进程/bundle | 调用方 × 目标 app |
| 开发调试重置 | `tccutil reset ScreenCapture` | `tccutil reset Accessibility` | `tccutil reset AppleEvents` |

### 骨架代码（查询 → 引导 → 轮询）

```swift
// 1. 查询（同步，适合 UI）
let granted = CGPreflightScreenCaptureAccess()

// 2. 引导用户打开系统设置深链
let url = URL(string:
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
NSWorkspace.shared.open(url)

// 3. 轮询恢复（1 s 间隔，见 ObservablePermissionsService.startMonitoring）
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    Task { @MainActor in service.checkPermissions() }
}
```

## 新项目落地步骤（How to apply）

1. **查询**三类权限初始状态，区分 `notDetermined`（从未弹过）与 `denied`（已拒绝）
2. **请求**时调用对应 API（`CGRequestScreenCaptureAccess` / `AXIsProcessTrustedWithOptions(prompt:true)` / `AEDeterminePermissionToAutomateTarget(..., askUser: true)`），注意 AppleEvents 必须对每个目标 app 单独请求
3. **引导**用户：调用失败后打开对应系统设置深链（三种权限各有不同的 URL，见 `ObservablePermissionsService.swift:208-218`），在 UI 上显示明确说明，而非仅抛出错误码，让用户知道去哪里操作
4. **轮询**：启动定时器（建议 1 s 间隔）持续调用 preflight/check，监听状态从 denied 到 authorized 的跳变；区分"用户刚授权生效"与"需要重启才能生效"两种情形再决定下一步
5. **恢复**：检测到 authorized 后停止轮询、清除错误提示、自动重试之前失败的操作（Screen Recording 例外：TCC 已更新但进程级缓存未刷新，需明确提示用户重启应用而非静默重试）
6. **封装**独立的 `PermissionState` 枚举与 `PermissionsStatus` 结构，与业务逻辑解耦，便于 UI 绑定
7. **暴露** CLI 子命令（如 `peekaboo permissions status`）让开发者和 CI 可脚本化查询当前权限状态；开发阶段用 `tccutil reset <Service> <BundleID>` 重置权限以复现首次安装场景，切勿在生产环境脚本中调用
8. **标注**测试中的权限依赖，用环境变量（如 `PEEKABOO_INCLUDE_AUTOMATION_TESTS=true`）来 gate 需要真实授权的测试，避免 CI 因权限缺失误报失败

## 常见陷阱（Pitfalls）

- **Screen Recording 改了不重启不生效** — 可观测信号：用户在系统设置勾选后，`CGPreflightScreenCaptureAccess()` 仍返回 false，截图报错不变。根因：TCC 在进程生命周期内缓存结果。处理方式：检测到这种"已授权但仍失败"的分歧时，提示"请重启应用"；来源：`PermissionsService.swift:25`注释明确说明 CLI 工具存在此问题，`ScreenCapturePermissionGate.swift:16` 用 `SCShareableContent` 兜底但最终仍可能需要重启。诊断命令：`peekaboo permissions status --all-sources` 对比 bridge host 与本地进程的状态差异。

- **entitlements 漏配导致 TCC prompt 不弹** — 可观测信号：第一次访问受保护资源直接返回 `errAEEventNotPermitted`（OSStatus −1743）或截图空白，系统**不弹任何 prompt**。根因：Info.plist 缺少对应的 `NSScreenCaptureUsageDescription` / `NSAppleEventsUsageDescription`，或 entitlements 未声明 `com.apple.security.automation.apple-events`（Peekaboo 的 entitlements 仅含此一项，见 `Apps/Mac/Peekaboo/Peekaboo.entitlements:5`）。排查：检查 entitlements 文件与 Info.plist Usage Description key 是否齐全；非 sandbox 的命令行工具不需要 entitlements 但必须有代码签名，否则 TCC 无法追踪。

## 延伸阅读

- Peekaboo：`docs/permissions.md`、`docs/security.md`、`docs/restore.md`
- Apple：[Transparency, Consent, and Control](https://developer.apple.com/documentation/security)
- 其它 playbook：[06 · AXorcist](./06-ax-automation-axorcist.md)、[07 · CGEvent](./07-cgevent-input-synthesis.md)、[08 · 屏幕捕获](./08-screen-capture-windows-spaces.md)、[12 · 测试策略](./12-testing-permission-gated.md)

---
*Last verified against Peekaboo @ `a9da0149`*
