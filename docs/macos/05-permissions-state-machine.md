---
summary: 'Model Screen Recording / Accessibility / AppleEvents as a five-state machine with restart hints for ReplayD-cached ScreenRec and per-target AppleEvents handling.'
read_when:
  - 'wiring up permission prompts and recovery flow for screen capture or AX automation'
  - 'debugging stuck permissions after user denied or system settings changed'
---

# 05 · 权限三态状态机

## TL;DR

macOS 将自动化敏感能力拆分为三类 TCC 权限：Screen Recording（截图/窗口枚举）、Accessibility（AX 操控/点击）、AppleEvents（per-app 脚本自动化）。三者共享同一逻辑状态机——`unknown → prompted → granted | denied → revoked`——但生效时机截然不同：Screen Recording 由 **ReplayD** 缓存进程级状态，改后**必须重启进程**才感知；Accessibility 是进程级 trust list，**热生效**可轮询；AppleEvents 是"调用方 × 目标 app"矩阵，**每个目标 app 独立弹 prompt**，对 System Events 已授权不等于对 Finder 已授权。正确建模这三类差异、以 1 s 轮询替代一次性检查感知状态跳变、在 ReplayD 分歧时给出重启提示而非静默重试，是稳健权限流的核心。Peekaboo 以 `PermissionsService` 承载查询/请求逻辑，`ObservablePermissionsService` + 1 s `Timer` 驱动 UI 实时同步，Mac app 的 `Permissions` 包装层加入了 0.5 s 防抖和 10 s 可选权限节流。

## Peekaboo 在哪里实现

| # | 文件 | 作用 |
|---|------|------|
| 1 | `Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/System/PermissionsService.swift:28` | `checkScreenRecordingPermission()` 用 `CGPreflightScreenCaptureAccess` 同步查询；注释明确说明 CLI 工具可能因 code-signature 缓存拿到错误的 false |
| 2 | `Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/Capture/ScreenCapturePermissionGate.swift:11` | `ScreenRecordingPermissionChecker`：preflight 返回 false 时 fallback 到 `SCShareableContent.current` 探针；有一次 transient retry |
| 3 | `Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/System/ObservablePermissionsService.swift:29` | `@Observable @MainActor` 包装层；`PermissionState` 三态枚举；`startMonitoring(interval:)` 以 1 s `Timer` 驱动 `checkPermissions()` |
| 4 | `Apps/Mac/Peekaboo/Core/Permissions.swift:120` | UI 层 1 s 循环；直接用 `CGPreflightScreenCaptureAccess()` 与 `AXIsProcessTrusted()`；0.5 s 防抖，可选权限 10 s 节流 |
| 5 | `Apps/Mac/Peekaboo/Features/Permissions/PermissionChecklistView.swift:88` | 权限引导 UI：`PermissionCapability.request(using:)` 失败后自动打开 deeplink |
| 6 | `Apps/Mac/Peekaboo/Features/Onboarding/PermissionsOnboarding.swift:74` | 首次启动权限引导窗口；`onAppear` 注册 monitoring，`onDisappear` 注销 |
| 7 | `Apps/CLI/Sources/PeekabooCLI/Commands/Agent/PermissionCommand+Requests.swift:44` | CLI 子命令 `permission request-screen-recording/accessibility/event-synthesizing` |

## 设计动机（Why）

**为什么三类权限必须分别处理**：

- **Screen Recording — ReplayD 进程级缓存**：TCC 数据库更新后，`ReplayD`（录屏守护进程）不会立即通知已在运行的进程。`CGPreflightScreenCaptureAccess()` 读的是该进程的 TCC 缓存副本，而不是实时数据库状态。因此用户在系统设置勾选后，正在运行的 app 或 CLI 进程仍会收到 `false`，必须重启才能刷新缓存。`ScreenCapturePermissionGate` 用 `SCShareableContent` 探针做二次确认，但即便探针成功，也只是说明 TCC 真实状态已授权——进程内的 CGWindowList capture 仍需重启。

- **Accessibility — 热生效轮询**：`AXIsProcessTrusted()` 每次调用都查询实时状态（不走 ReplayD 路径），可热生效。Peekaboo 以 1 s `Timer` 持续调用，检测到从 `denied` 跳变为 `authorized` 后立即清除错误提示、自动重试失败操作。

- **AppleEvents — per-app 矩阵**：TCC 为 AppleEvents 维护的是"调用方 bundle ID × 目标 app bundle ID"的二维表。`AEDeterminePermissionToAutomateTarget` 接受具体目标的 `AEDesc`，必须逐个目标调用，不能批量授权。`PermissionsService.checkAppleScriptPermission()` 以 `com.apple.systemevents` 为探针；对其它目标（Finder、Chrome、Mail）需要分别请求（见非原生环境节）。

- **TCC.db 与 sandbox**：非沙盒 CLI 工具的 TCC 条目写在 `~/Library/Application Support/com.apple.TCC/TCC.db`；沙盒 app 条目写在各自 container 下，且 `tccutil` 命令行工具基于 bundle ID 而非 container 路径操作，需注意区分。

早期实现依赖一次性检查：启动时查一次，失败就抛错。结果是用户授权后必须手动重启。状态机 + 轮询解决了 AX 的问题，ReplayD 缓存问题则需要单独"重启提示"流程（见 Pattern 4）。

## 核心模式（Pattern）

### 状态机图

```
     ┌─────────────────────────────────────────────────────┐
     │                                                     │
  unknown ──request()──► prompted                          │
                           │                               │
           ┌───────────────┴───────────────┐               │
           ▼ user granted                  ▼ user denied   │
       granted ◄──── 1 s 轮询 ─────────► denied            │
           │                               │               │
           │ (Screen Recording:             │               │
           │  ReplayD 缓存未刷             │               │
           │  → 需重启进程)               │               │
           │                               │               │
           ▼                               ▼               │
       in_effect                   denied_sticky ──────────┘
     (hot reload,                  (必须手工进系统
      AX only)                      设置再勾选)
           │
           ▼ 用户在系统设置取消
       revoked ──────────────────────────────────────────►│
                                                           │
     ◄──────────────────── tccutil reset ─────────────────┘
```

### 三类权限对照

| 维度 | Screen Recording | Accessibility | AppleEvents |
|------|-----------------|---------------|-------------|
| 查询 API | `CGPreflightScreenCaptureAccess()` | `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions` | `AEDeterminePermissionToAutomateTarget` |
| 热生效 | **否**（须重启进程） | **是** | **是**（per-app prompt 后立即生效） |
| 粒度 | 进程/bundle | 进程/bundle | 调用方 × 目标 app |
| 首次拒绝后 | 用户须进系统设置手动勾选 | 同左 | `tccutil reset AppleEvents <id>` 后可再触发 |
| 开发调试重置 | `tccutil reset ScreenCapture <id>` | `tccutil reset Accessibility <id>` | `tccutil reset AppleEvents <id>` |
| deeplink URL | `?Privacy_ScreenCapture` | `?Privacy_Accessibility` | `?Privacy_Automation` |

### Pattern 1 · 查询 → 引导 → 轮询（基础流）

```swift
// 查询（同步，适合 UI 1 s 轮询）
let screenOK = CGPreflightScreenCaptureAccess()
let axOK     = AXIsProcessTrusted()

// 引导：打开系统设置深链（三个权限各自的 URL）
let url = URL(string:
    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
NSWorkspace.shared.open(url)

// 轮询恢复（见 ObservablePermissionsService.startMonitoring / Permissions.startMonitoringTimer）
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    Task { @MainActor in
        service.checkPermissions()
        // 发现 authorized → 停止轮询，清除错误提示，重试失败操作
    }
}
```

### Pattern 2 · AppleEvents 多 target 处理

```swift
// 必须对每个目标 app 单独调用
func checkAppleEvents(target bundleID: String) -> Bool {
    guard var desc = makeAETargetDesc(bundleID: bundleID) else { return false }
    defer { AEDisposeDesc(&desc) }
    let status = AEDeterminePermissionToAutomateTarget(
        &desc,
        AEEventClass(0x636F7265),  // 'core'
        AEEventID(0x67657464),     // 'getd'
        false                      // askUser: false = 只查，不弹
    )
    return status == noErr
}

// 请求（askUser: true 才弹 prompt）
func requestAppleEvents(target bundleID: String) -> Bool {
    guard var desc = makeAETargetDesc(bundleID: bundleID) else { return false }
    defer { AEDisposeDesc(&desc) }
    let status = AEDeterminePermissionToAutomateTarget(&desc,
        AEEventClass(0x636F7265), AEEventID(0x67657464), true)
    return status == noErr
}
```

对应 Peekaboo 实现：`PermissionsService.swift:167-200`

### Pattern 3 · SCShareableContent 双重确认（规避 ReplayD 缓存）

```swift
// ScreenRecordingPermissionChecker（ScreenCapturePermissionGate.swift:9-39）
func hasPermission() async -> Bool {
    // 第一道：CGPreflight（快速，但对 CLI / 重新编译的 bundle 不可靠）
    if CGPreflightScreenCaptureAccess() { return true }

    // 第二道：SCShareableContent 探针（实际发起 capture 请求，触发 TCC 真实判断）
    do {
        _ = try await SCShareableContent.current
        return true   // TCC 真实授权
    } catch {
        return false  // 真实拒绝
    }
}
```

**注意**：探针返回 `true` 只代表 TCC 数据库已授权，不代表 `CGPreflightScreenCaptureAccess()` 同步 API 会立刻返回 `true`——该 API 仍可能读缓存。仅靠探针通过就跳过重启提示会导致 `CGWindowListCreate` 等同步 API 仍失败。

### Pattern 4 · ReplayD 缓存"重启提示"流程

当 ScreenRec 探针 (`SCShareableContent`) 通过但 `CGPreflightScreenCaptureAccess()` 仍返回 `false` 时，说明 TCC 数据库已更新但进程缓存未刷：

```
SCShareableContent 成功 ──────► TCC 真实状态 = granted
         │
         ▼
CGPreflightScreenCaptureAccess() 仍返回 false
         │
         ▼
  ┌─────────────────────────────────────┐
  │ ReplayD 进程级缓存未刷新             │
  │ → 提示"请重启 Peekaboo"            │
  │ → 可选：提供"立即重启"按钮          │
  │    （见 restartApp() 辅助函数）      │
  └─────────────────────────────────────┘
         │ 用户重启后
         ▼
CGPreflightScreenCaptureAccess() 返回 true  ✓
```

不要在这种情况下静默重试——`CGWindowListCreate` 仍然失败，无限重试会让用户困惑。

### Pattern 5 · 首次启动 vs 升级时的权限 prompt 策略

**问题**：三个权限同时弹会让用户一次性看到三个对话框，体验极差，且用户通常不看说明就拒绝。

**策略**：

```
首次启动 ─────► 仅请求 Screen Recording（最高优先级）
                  │
                  ▼ 用户授权 or 跳过
              请求 Accessibility
                  │
                  ▼ 用户授权 or 跳过
              AppleEvents 延迟到首次使用 AppleScript 功能时请求

升级安装 ──────► 比对上一次已知状态
                  │ 新增权限需求
                  ▼
              仅在用户触发相关功能时弹，不在启动时弹

CI / --headless ─► 跳过所有 interactive prompt，返回状态码
```

Peekaboo 的 `PermissionsOnboarding` 实现此策略：`permissionsOnboardingSeenKey` 存储是否见过引导页，`currentPermissionsOnboardingVersion` 管理升级时是否重新引导（`PermissionsOnboarding.swift:4-6`）。

## 完整代码示例（Starter Code）

以下是可直接嵌入 macOS 14+ 项目的独立文件，覆盖三类权限状态机的核心逻辑。结构与 Peekaboo 保持一致，不依赖 Peekaboo 内部模块。

**权限要求**：Entitlements 需包含 `com.apple.security.automation.apple-events`（AppleEvents 发送方）；Info.plist 需含 `NSScreenCaptureUsageDescription`、`NSAccessibilityUsageDescription`、`NSAppleEventsUsageDescription`。

**嵌入方式**：将此文件加入任意 macOS SPM target 或 Xcode target。依赖仅有 `AppKit`、`ApplicationServices`、`CoreGraphics`、`ScreenCaptureKit`（macOS 12.3+）、`Observation`（macOS 14+）。

```swift
// PermissionsStateMachine.swift — Starter Code for Playbook 05
// Compiles on macOS 14+. Requires ScreenCaptureKit (macOS 12.3+) for SCShareableContent probe.
//
// macOS version notes:
//   - CGPreflightScreenCaptureAccess / CGRequestScreenCaptureAccess: macOS 10.15+
//   - AEDeterminePermissionToAutomateTarget: macOS 10.14+
//   - SCShareableContent.current: macOS 12.3+
//   - @Observable / Observation framework: macOS 14+
//
// Entitlements required for sandboxed apps:
//   com.apple.security.automation.apple-events = true
//
// Info.plist keys required (without these, TCC never prompts):
//   NSScreenCaptureUsageDescription
//   NSAccessibilityUsageDescription
//   NSAppleEventsUsageDescription

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import ScreenCaptureKit
import os.log

// MARK: - Permission Kind

/// Three distinct TCC permission categories with different lifecycle semantics.
public enum PermissionKind: Hashable, Sendable {
    /// Screen Recording — managed by ReplayD, requires process restart to take effect.
    case screenRecording
    /// Accessibility — hot-reloadable, polled via AXIsProcessTrusted().
    case accessibility
    /// Apple Events — per-target-app matrix, each target app requires its own TCC entry.
    case appleEvents(targetBundleID: String)
}

// MARK: - Permission State

/// Five-state machine for a single permission kind.
/// - `unknown`:  never queried; initial state before first check
/// - `prompted`: prompt was shown; waiting for user response
/// - `granted`:  TCC database says authorized (may need restart for ScreenRec to take effect)
/// - `denied`:   user refused; sticky — requires manual System Settings toggle or tccutil reset
/// - `revoked`:  was granted, now taken away (user unchecked in System Settings)
public enum PermissionState: String, Sendable, CaseIterable {
    case unknown
    case prompted
    case granted
    case denied
    case revoked

    public var displayName: String {
        switch self {
        case .unknown:  "Not Checked"
        case .prompted: "Prompted"
        case .granted:  "Granted"
        case .denied:   "Denied"
        case .revoked:  "Revoked"
        }
    }

    public var isUsable: Bool { self == .granted }
}

// MARK: - System Settings Deep Links

/// Open these URLs to navigate the user to the correct Privacy pane.
public enum PermissionSettingsURL {
    public static let screenRecording = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    public static let accessibility = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    public static let automation = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    public static func url(for kind: PermissionKind) -> URL {
        switch kind {
        case .screenRecording:      return screenRecording
        case .accessibility:        return accessibility
        case .appleEvents:          return automation
        }
    }
}

// MARK: - PermissionsService (actor)

/// Core query and request service. Thread-safe via actor isolation.
/// Mirrors Peekaboo's `PermissionsService` in PeekabooAutomationKit.
public actor PermissionsService {
    private let logger = Logger(subsystem: "com.example.app", category: "PermissionsService")

    public init() {}

    // MARK: Screen Recording

    /// Synchronous preflight check (fast, suitable for 1 s UI polling).
    /// WARNING: unreliable for CLI tools / rebuilt bundles due to ReplayD caching.
    /// Use checkScreenRecordingActual() for CLI or when detecting ReplayD divergence.
    public func checkScreenRecording() -> PermissionState {
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        }
        return .granted  // Pre-10.15: no TCC for screen recording
    }

    /// Authoritative async check via SCShareableContent probe.
    /// Returns .granted if TCC database is authorized, even if process-level cache is stale.
    /// A .granted here with checkScreenRecording() == .denied means ReplayD cache is stale
    /// — prompt user to restart rather than silently retrying CGWindowList operations.
    @available(macOS 12.3, *)
    public func checkScreenRecordingActual() async -> PermissionState {
        // Fast path
        if CGPreflightScreenCaptureAccess() { return .granted }

        // Probe via SCShareableContent — hits TCC directly, bypasses process cache
        do {
            _ = try await SCShareableContent.current
            logger.info("SCShareableContent probe: TCC granted (ReplayD cache stale)")
            return .granted
        } catch {
            logger.info("SCShareableContent probe: TCC denied — \(error)")
            return .denied
        }
    }

    /// Request Screen Recording permission (triggers TCC prompt on first call).
    /// Returns the current state after the request. Does NOT block until user responds.
    @discardableResult
    public func requestScreenRecording() -> PermissionState {
        if #available(macOS 10.15, *) {
            _ = CGRequestScreenCaptureAccess()
        }
        return checkScreenRecording()
    }

    // MARK: Accessibility

    /// Hot-reloadable: AXIsProcessTrusted() queries live TCC state each call.
    public func checkAccessibility() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Request Accessibility permission.
    /// First refusal is sticky — subsequent calls to AXIsProcessTrustedWithOptions(prompt:true)
    /// do NOT re-show the prompt. User must manually enable in System Settings.
    @discardableResult
    public func requestAccessibility() -> PermissionState {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
        _ = AXIsProcessTrustedWithOptions(options)
        return checkAccessibility()
    }

    // MARK: Apple Events (per-target)

    /// Check AppleEvents permission for a specific target app.
    /// Each target bundle ID has its own TCC entry — authorized for System Events
    /// does NOT imply authorized for Finder or Chrome.
    public func checkAppleEvents(targetBundleID: String) -> PermissionState {
        guard var desc = Self.makeAETargetDesc(bundleID: targetBundleID) else { return .denied }
        defer { AEDisposeDesc(&desc) }

        let status = AEDeterminePermissionToAutomateTarget(
            &desc,
            AEEventClass(0x636F_7265),  // 'core'
            AEEventID(0x6765_7464),     // 'getd'
            false                        // askUser: false — query only
        )
        switch status {
        case noErr:                   return .granted
        case OSStatus(-1743):         return .denied    // errAEEventNotPermitted
        case OSStatus(procNotFound):  return .unknown   // target app not running
        default:                      return .unknown
        }
    }

    /// Request AppleEvents permission for a specific target (shows prompt if not yet decided).
    /// Target app must be running — call launchIfNeeded(bundleID:) first.
    @discardableResult
    public func requestAppleEvents(targetBundleID: String) -> PermissionState {
        guard var desc = Self.makeAETargetDesc(bundleID: targetBundleID) else { return .denied }
        defer { AEDisposeDesc(&desc) }

        let status = AEDeterminePermissionToAutomateTarget(
            &desc,
            AEEventClass(0x636F_7265),
            AEEventID(0x6765_7464),
            true  // askUser: true — prompt if undecided
        )
        if status == OSStatus(procNotFound) {
            logger.debug("AE target \(targetBundleID) not running; launching and retrying")
            launchApp(bundleID: targetBundleID)
            // Brief yield so the launched app can register with TCC
            Thread.sleep(forTimeInterval: 0.5)
            return requestAppleEvents(targetBundleID: targetBundleID)
        }
        return checkAppleEvents(targetBundleID: targetBundleID)
    }

    // MARK: Helpers

    private static func makeAETargetDesc(bundleID: String) -> AEDesc? {
        guard let data = bundleID.data(using: .utf8), !data.isEmpty else { return nil }
        var desc = AEDesc()
        let status = data.withUnsafeBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return OSStatus(paramErr) }
            return OSStatus(AECreateDesc(
                DescType(typeApplicationBundleID), base, buf.count, &desc))
        }
        guard status == noErr else { return nil }
        return desc
    }

    private func launchApp(bundleID: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-b", bundleID]
        try? p.run()
    }
}

// MARK: - ReplayD Cache Detection

/// Detects the divergence between CGPreflight (process cache) and SCShareableContent (TCC truth).
/// Returns true when the user has authorized Screen Recording but the running process
/// hasn't seen the update yet — this is the signal to show a "Please restart" prompt.
@available(macOS 12.3, *)
public func detectReplayDStaleness() async -> Bool {
    let preflight = CGPreflightScreenCaptureAccess()
    if preflight { return false }  // No divergence — either both false or preflight already true

    let service = PermissionsService()
    let actual = await service.checkScreenRecordingActual()
    return actual == .granted  // TCC says yes, process says no → stale cache
}

// MARK: - Restart Helper

/// Relaunch the current app. Call only after confirming user intent.
/// Uses NSApplication.shared.relaunch() on macOS, which forks a watcher process
/// and terminates + relaunches the current bundle.
@MainActor
public func restartApp() {
    let url = Bundle.main.bundleURL
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = false
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
    NSApp.terminate(nil)
}

// MARK: - ObservablePermissionsService

/// UI-friendly observable wrapper. Drives a 1 s polling timer and broadcasts state changes.
/// Mirrors Peekaboo's ObservablePermissionsService in PeekabooAutomationKit.
@available(macOS 14.0, *)
@Observable
@MainActor
public final class ObservablePermissionsService {

    // MARK: Published State

    public private(set) var screenRecordingState: PermissionState = .unknown
    public private(set) var accessibilityState: PermissionState   = .unknown
    /// AppleEvents state for the most-recently-queried target (default: System Events).
    public private(set) var appleEventsState: PermissionState     = .unknown

    /// True when ScreenRec TCC is granted but process cache is stale (ReplayD divergence).
    public private(set) var screenRecordingNeedsRestart = false

    public var hasRequiredPermissions: Bool {
        screenRecordingState == .granted && accessibilityState == .granted
    }

    // MARK: Private

    private let core = PermissionsService()
    private var monitorTimer: Timer?
    public private(set) var isMonitoring = false
    private var appleEventsTarget = "com.apple.systemevents"
    private let logger = Logger(subsystem: "com.example.app", category: "ObservablePermissions")

    // MARK: Init

    public init() {
        Task { @MainActor in await self.refresh() }
    }

    // MARK: Monitoring

    /// Begin periodic polling. Default interval: 1 s.
    public func startMonitoring(interval: TimeInterval = 1.0) {
        guard !isMonitoring else { return }
        isMonitoring = true
        Task { @MainActor in await refresh() }
        monitorTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        logger.info("Permission monitoring started (interval: \(interval) s)")
    }

    public func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitorTimer?.invalidate()
        monitorTimer = nil
        logger.info("Permission monitoring stopped")
    }

    // MARK: Refresh

    public func refresh() async {
        // Screen Recording: fast sync check first
        let prevScreen = screenRecordingState
        screenRecordingState = await core.checkScreenRecording()

        // Detect ReplayD staleness (async SCShareableContent probe) when preflight says denied
        if #available(macOS 12.3, *), screenRecordingState == .denied {
            let stale = await detectReplayDStaleness()
            if stale {
                screenRecordingState  = .granted  // TCC truth wins for display
                screenRecordingNeedsRestart = true
                logger.warning("ReplayD cache stale: TCC granted, preflight denied — restart required")
            } else {
                screenRecordingNeedsRestart = false
            }
        } else {
            screenRecordingNeedsRestart = false
        }

        // Detect revocation (was granted, now denied)
        if prevScreen == .granted, screenRecordingState == .denied {
            screenRecordingState = .revoked
        }

        accessibilityState = await core.checkAccessibility()
        appleEventsState   = await core.checkAppleEvents(targetBundleID: appleEventsTarget)
    }

    // MARK: Request

    /// Request Screen Recording. If ReplayD cache is stale after grant, set needsRestart.
    public func requestScreenRecording() async {
        await core.requestScreenRecording()
        await refresh()
    }

    public func requestAccessibility() async {
        await core.requestAccessibility()
        await refresh()
    }

    /// Request AppleEvents for a specific target. Each target app needs its own request.
    public func requestAppleEvents(target bundleID: String) async {
        appleEventsTarget = bundleID
        await core.requestAppleEvents(targetBundleID: bundleID)
        await refresh()
    }

    /// Open the System Settings pane for the given permission kind.
    public func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(PermissionSettingsURL.url(for: kind))
    }
}

// MARK: - CLI Subcommand Skeleton

/// Skeleton for `peekaboo permissions status/grant/reset` CLI subcommands.
/// Mirrors Peekaboo's PermissionsCommand in Apps/CLI/Sources/PeekabooCLI/Commands/Agent/.
public struct PermissionsCLI {
    private let service = PermissionsService()

    /// `peekaboo permissions status` — print current state, exit 0 if all granted.
    public func status() async -> Int32 {
        let screen = await service.checkScreenRecording()
        let ax     = await service.checkAccessibility()
        let ae     = await service.checkAppleEvents(targetBundleID: "com.apple.systemevents")

        print("Screen Recording : \(screen.displayName)")
        print("Accessibility    : \(ax.displayName)")
        print("Apple Events     : \(ae.displayName)")

        // Check for ReplayD divergence
        if #available(macOS 12.3, *) {
            let stale = await detectReplayDStaleness()
            if stale { print("WARNING: Screen Recording TCC granted but process cache stale — restart app") }
        }

        return (screen == .granted && ax == .granted) ? 0 : 1
    }

    /// `peekaboo permissions grant` — trigger prompts for all ungrated permissions.
    public func grant() async {
        let screen = await service.checkScreenRecording()
        if screen != .granted { await service.requestScreenRecording() }

        let ax = await service.checkAccessibility()
        if ax != .granted { await service.requestAccessibility() }
    }

    /// `peekaboo permissions reset <bundleID>` — dev tool: reset a specific permission.
    /// Internally delegates to `tccutil reset <Service> <bundleID>`.
    public func reset(service tccService: String, bundleID: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", tccService, bundleID]
        try? p.run()
        p.waitUntilExit()
        print("tccutil reset \(tccService) \(bundleID) exited: \(p.terminationStatus)")
    }
}
```

## 新项目落地步骤（How to apply）

1. **在 Info.plist 添加 Usage Description keys**（没有这些 key，TCC 不弹 prompt，直接静默拒绝）：
   - `NSScreenCaptureUsageDescription` — 说明为何需要录屏
   - `NSAccessibilityUsageDescription` — 说明为何需要辅助功能
   - `NSAppleEventsUsageDescription` — 说明为何需要控制其它 app

2. **在 Entitlements 文件中添加**（沙盒 app 必须，非沙盒 CLI 工具可省略）：
   - `com.apple.security.automation.apple-events = true`
   - 可选：`com.apple.security.temporary-exception.apple-events.<target-bundle-id> = true`（预声明允许的目标 app，减少运行时弹窗数量）

3. **复制 `PermissionsStateMachine.swift`** 到项目 `Sources/` 目录。删除不需要的 `PermissionsCLI`（如果是纯 GUI app）或 `ObservablePermissionsService`（如果是纯 CLI 工具）。

4. **查询三类权限初始状态**，区分 `unknown`（从未查询）与 `denied`（已拒绝）：未查询时显示"点击授权"；已拒绝时显示"请在系统设置重新开启"（因为 AX 首次拒绝后 `prompt:true` 不再弹）。

5. **逐步请求**，遵循 Pattern 6 的延迟策略：启动时只请求 Screen Recording；Accessibility 在用户第一次触发需要 AX 的功能时请求；AppleEvents 在用户配置特定 app 自动化时请求，不提前请求。

6. **启动 1 s 轮询**（`startMonitoring()`）；检测到 `denied → granted` 跳变后：AX 立即清除错误提示并重试；Screen Recording 检查 `screenRecordingNeedsRestart` 标志，为 true 时显示"请重启应用"而非静默重试。

7. **GUI 引导**：每个权限项配一个"Grant"按钮 + 失败时自动 `NSWorkspace.shared.open(settingsURL)`，见 `PermissionChecklistView.swift` 的模式。不要只抛错误码——用户需要知道去哪里操作。

8. **暴露 CLI 子命令**：`permissions status`（0/1 退出码方便 CI 使用）、`permissions grant`（触发所有 prompt）、`permissions reset <service> <bundleID>`（开发调试用，生产代码不调用）。

9. **为开发模式提供 tccutil 重置脚本**（`scripts/reset-permissions.sh`）：

   ```bash
   #!/bin/bash
   # Usage: ./scripts/reset-permissions.sh com.example.MyApp
   BUNDLE_ID="${1:?Usage: $0 <bundle-id>}"
   tccutil reset ScreenCapture "$BUNDLE_ID"
   tccutil reset Accessibility "$BUNDLE_ID"
   tccutil reset AppleEvents   "$BUNDLE_ID"
   tccutil reset All           "$BUNDLE_ID"   # belt-and-suspenders
   echo "Permissions reset for $BUNDLE_ID"
   ```

10. **标注测试中的权限依赖**：用 `PEEKABOO_INCLUDE_AUTOMATION_TESTS=true` 环境变量 gate 需要真实授权的测试（见 [12 · 测试策略](./12-testing-permission-gated.md)）。CI 不要调用 `tccutil reset` — 在有权限的 macOS runner 上直接跑，无权限的 runner 上 gate 掉。

## 替代方案对比（When NOT to use）

| 方案 | 优点 | 缺点 | 何时选 |
|------|------|------|--------|
| **本方案：状态机 + 三类分管 + 1 s 轮询** | 状态完整；UI 实时同步；ReplayD 分歧可检测；CLI 友好 | 1 s 轮询有微小 CPU 开销；代码量较多 | 通用 GUI + CLI 应用（推荐） |
| **一次性 query at startup** | 实现简单，≤20 行代码 | 用户在系统设置改了不感知；AX 授权后需重启才能恢复 | 一次性 CLI 任务、脚本工具 |
| **NSWorkspace / DistributedNotificationCenter 事件驱动** | 事件驱动，无轮询开销 | 错过用户主动改的场景；通知不保证送达 | 严格性能敏感 + 仅需检测 app 切换触发的变化 |
| **私有 TCC API（`/usr/libexec/tccutil-helper`、直接读 TCC.db）** | 可得到完整授权客户端列表；可知道 prompt 历史 | 私有/未公开 API；沙盒和 MAS 完全不可用；SIP 开启下 TCC.db 不可读 | 仅自用调试工具，不发布 |
| **完全不查询，直接调用** | 零样板代码 | 失败时 UX 糟糕（空白截图、无报错）；极难调试 | 文档示例、一次性脚本 |

## 非原生环境（AppleEvents target 行为差异）

### AppleEvents per-target 行为对照

AppleEvents 权限不是全局开关，是"调用方 × 目标 app"二维表。以下是常见目标 app 的行为差异：

#### Chrome / Edge（`com.google.Chrome` / `com.microsoft.edgemac`）

- **Prompt 时机**：第一次向 Chrome 发送 `core/getd` 事件时弹出
- **缓存行为**：授权后 per-Chrome-instance 缓存；Chrome 版本升级通常保留（bundle ID 不变）
- **注意**：Chrome 沙盒渲染进程使用不同的 bundle ID（`com.google.Chrome.helper`），需分别授权
- **AppleScript 实际用途**：执行页面内 JavaScript（`do JavaScript`）—— 但此功能默认关闭，需在 Chrome 设置中启用"Allow JavaScript from Apple Events"
- **Peekaboo 实证**：`PermissionsService.swift:115-136` 用 `com.apple.systemevents` 探针而非 Chrome，因为 Peekaboo 不直接向 Chrome 发送 AppleEvents；实际 Chrome 控制通过 CDP 路径

#### Safari（`com.apple.Safari`）

- **额外开关**：即使 TCC 授权，仍需在 Safari → 偏好设置 → 高级 → 勾选"在菜单栏中显示开发"→ 开发菜单 → "Allow JavaScript from Apple Events"才能在页面内执行脚本
- **Prompt 时机**：与其它 app 相同，首次发事件时弹
- **macOS 14+ 变化**：Privacy & Security 面板将 Automation 条目改名为 "Allow JavaScript from Apple Events"（仅 Safari），比其它 app 有额外的二步授权

#### Mail / Notes / Finder（Apple 系统 app）

- **独立 TCC 子条目**：每个都有自己的 TCC 条目，互不影响
- **Mail 权限链**：Mail 的 AppleScript 自动化可能间接触发联系人（Contacts）权限请求，出现连环弹窗
- **Finder**：`com.apple.finder`，AppleScript 支持最完整，用于文件操作自动化
- **tccutil 重置**：`tccutil reset AppleEvents com.apple.finder` 对 Apple 系统 app 有效（非 MAS 分发的系统 app）

#### VSCode / Discord / Slack（Electron）

- **实际情况**：Electron app 通常**不响应** AppleEvents（没有实现 AppleScript dictionary）
- **errAEEventNotPermitted vs procNotFound vs noErr**：`AEDeterminePermissionToAutomateTarget` 对 Electron app 可能返回 `procNotFound`（未运行）或 `-1728`（not scriptable），而非 `-1743`（permission denied），需要区分
- **正确路径**：向 Electron app 发 AppleEvents 几乎无意义；改用 CDP（Chrome DevTools Protocol）或 Electron IPC。Peekaboo 对 Electron app 走 CGEvent + AX `setValue` 路径（见 [07 · CGEvent](./07-cgevent-input-synthesis.md)）

#### macOS 12 vs 14+ 的 TCC 行为变化

- **macOS 12 之前**：`com.apple.tccd` 每次 AEDeterminePermission 调用都查数据库，较慢
- **macOS 13+**：tccd 增加了会话级缓存，`procNotFound` 后立即重试可能拿到缓存结果
- **macOS 14+**：`Privacy & Security` 面板 UI 重新设计，Automation 条目位置改变，deeplink 不变

#### Peekaboo 实证

`PermissionsService.swift:115-136` 以 `com.apple.systemevents` 为默认探针，原因是：
- System Events 是最常见的 AppleScript 目标（控制 UI element、Finder 等都通过它）
- System Events 总是在运行（launchd daemon），不需要先 launch
- 用户授权 System Events 后大多数 AppleScript 场景即可用

对于需要控制特定 app 的场景（如 Mail、Safari），需要在首次使用时额外请求该 app 的 AppleEvents 权限，见 Pattern 2。

## 调试与取证（Debug & Forensics）

### 症状 → 命令 → 根因 映射

| 症状 | 排查命令 | 根因 |
|------|---------|------|
| ScreenRec 用户已勾但 Peekaboo 仍拒绝 | `swift -e 'import CoreGraphics; print(CGPreflightScreenCaptureAccess())'` + 重启 app 验证 | ReplayD 进程级缓存，改后须重启才感知 |
| `CGPreflightScreenCaptureAccess()` false 但 SCShareableContent 成功 | `peekaboo permissions status --all-sources` 对比两个来源 | ReplayD 缓存分歧，提示重启 |
| AX prompt 弹了但拒绝后不再弹 | `tccutil reset Accessibility com.example.app` | TCC 拒绝是粘性状态，重置后才能再触发 prompt |
| AppleEvents 不弹窗，直接返回 -1743 | 检查 Info.plist 是否含 `NSAppleEventsUsageDescription`；`codesign -d --entitlements - /path/to.app` 验 entitlements | 没有 Usage Description key，TCC 静默拒绝；或 entitlements 漏配 `com.apple.security.automation.apple-events` |
| 找不到 entitlements 或权限报错 | `codesign -d --entitlements - /path/to/Peekaboo.app` | entitlements 漏配或代码签名失效 |
| 沙盒下 AppleEvents 被静默拒绝 | `log stream --predicate 'subsystem == "com.apple.TCC"' --debug` | sandbox 阻断，需加 `com.apple.security.automation.apple-events` 并列举允许的 bundle ID |
| TCC.db 状态异常 | `sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "select client,service,auth_value from access where client like '%peekaboo%' or client like '%example%'"` （需 SIP 关闭） | 数据库本身陈旧或 bundle ID 已改变 |
| CLI 工具权限状态与 .app 不同 | `peekaboo permissions status` 观察 Source 行（Bridge vs local） | TCC 按 bundle/code-signature 分别追踪；CLI 与 .app bundle ID 不同 |

### 关键工具

```bash
# 重置某个权限（开发/测试利器）
tccutil reset ScreenCapture   com.example.MyApp
tccutil reset Accessibility   com.example.MyApp
tccutil reset AppleEvents     com.example.MyApp
tccutil reset All             com.example.MyApp   # 全量重置

# 实时跟踪 TCC 决策（macOS 12+）
log stream --predicate 'subsystem == "com.apple.TCC"' --debug --level debug

# 验证 app 签名 + entitlements
codesign -d --entitlements - /Applications/Peekaboo.app
codesign -vvv /Applications/Peekaboo.app

# 查看 ScreenCapture 已授权的 bundle 列表（需 SIP 关闭）
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "select client,auth_value,auth_reason from access where service='kTCCServiceScreenCapture';"

# 快速 preflight 测试（无需运行 app）
swift -e 'import CoreGraphics; print("ScreenRec:", CGPreflightScreenCaptureAccess())'
swift -e 'import ApplicationServices; print("AX:", AXIsProcessTrusted())'

# 打开对应系统设置面板
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

# 检查 CLI 工具代码签名（无签名则 TCC 无法追踪）
codesign --verify --verbose=4 $(which peekaboo)
```

## 常见陷阱（Pitfalls）

### 陷阱 1 · Screen Recording 改了不重启不生效

**症状**：用户在系统设置勾选后，`CGPreflightScreenCaptureAccess()` 仍返回 false，截图空白或报错不变。

**可观测信号**：`SCShareableContent.current` 成功（TCC 已更新），但 `CGWindowListCopyWindowInfo` 返回空列表或 `CGPreflightScreenCaptureAccess()` 仍为 false。

**处理**：检测探针 vs preflight 的分歧（Pattern 3），提示"请重启 Peekaboo"；不要静默重试 CGWindowList 操作——无限循环无法自愈。

**来源**：`PermissionsService.swift:25-26` 注释；`ScreenCapturePermissionGate.swift:17-18` 的 fallback 注释。

---

### 陷阱 2 · AX 首次拒绝后 prompt 永远不再弹

**症状**：调用 `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` 后什么都没有发生，用户不知道去哪里开启。

**可观测信号**：第一次拒绝 AX prompt 后，后续调用 `AXIsProcessTrustedWithOptions(prompt: true)` 不弹对话框，只返回 false。

**处理**：检测拒绝状态后，主动显示"请在系统设置 → 辅助功能 中开启 Peekaboo"，并提供 deeplink 按钮；`tccutil reset Accessibility <bundleID>` 是开发阶段的重置手段。

---

### 陷阱 3 · entitlements 漏配导致 TCC prompt 不弹

**症状**：第一次访问受保护资源直接返回 `errAEEventNotPermitted`（OSStatus −1743）或截图空白，系统不弹任何 prompt。

**可观测信号**：`codesign -d --entitlements - Peekaboo.app` 输出中没有 `com.apple.security.automation.apple-events`，或 Info.plist 缺少 `NSAppleEventsUsageDescription`。

**处理**：检查 entitlements 文件（Peekaboo 仅声明 `com.apple.security.automation.apple-events`，见 `Apps/Mac/Peekaboo/Peekaboo.entitlements:5`）；非沙盒 CLI 工具不需要 entitlements 但必须有代码签名，否则 TCC 无法追踪 bundle。

---

### 陷阱 4 · AppleEvents 在沙盒下 entitlements 复杂

**症状**：沙盒 app 发 AppleEvent 到 Finder，收到 `<NSXPCConnectionError>` 或 `errAEEventNotPermitted`，但非沙盒版本正常。

**可观测信号**：`log stream --predicate 'subsystem == "com.apple.TCC"' --debug` 中看到 `deny` 条目，源是 sandbox policy 而非 user decision。

**处理**：在 entitlements 中添加：
```xml
<key>com.apple.security.automation.apple-events</key>
<true/>
<key>com.apple.security.temporary-exception.apple-events.com.apple.finder</key>
<true/>
```
每个要控制的 app bundle ID 都需要单独声明，Apple 审核会检查这些例外是否合理。

---

### 陷阱 5 · `tccutil reset` 对 MAS 应用无效

**症状**：执行 `tccutil reset Accessibility com.example.App` 后输出成功，但 app 权限状态不变。

**可观测信号**：App 通过 Mac App Store 分发，bundle ID 与 codesigning identifier 不一致；`tccutil` 使用的是 codesigning identifier。

**处理**：用 `codesign -d -r - /Applications/App.app` 获取真实的 signing identifier，用该值调用 `tccutil reset`。

---

### 陷阱 6 · `AXIsProcessTrustedWithOptions` 第二次调用需不同方式触发

**症状**：用户在系统设置里新勾选了 app，但 app 内界面没变（显示未授权）。

**可观测信号**：`AXIsProcessTrusted()` 仍返回 false（这个 API 是热生效的，不应该有此问题）；检查是否混用了 `AXIsProcessTrustedWithOptions` 的缓存。

**处理**：轮询路径统一用 `AXIsProcessTrusted()`（无参数版本），不用 `AXIsProcessTrustedWithOptions`。后者的 `prompt:true` 只在需要弹 prompt 时调用一次，轮询时不要带 `prompt:true`（会产生副作用）。

## 延伸阅读

- Peekaboo 内部：`docs/permissions.md`、`docs/security.md`、`docs/restore.md`
- Apple：[Transparency, Consent, and Control (TCC)](https://developer.apple.com/documentation/security)、[AEDeterminePermissionToAutomateTarget](https://developer.apple.com/documentation/coreservices/1447734-aedeterminepermissiontoautomatet)、[Privacy-Sensitive Resources](https://developer.apple.com/documentation/bundleresources/information-property-list/protected-resources)
- Howard Oakley TCC 博客系列：[Eclectic Light – TCC](https://eclecticlight.co/tag/tcc/)（深度解析 TCC 数据库结构与各 macOS 版本差异）
- 其它 playbook：[06 · AXorcist](./06-ax-automation-axorcist.md)（AX 权限前置）、[07 · CGEvent](./07-cgevent-input-synthesis.md)（Input Monitoring / Event Synthesizing 权限）、[08 · 屏幕捕获](./08-screen-capture-windows-spaces.md)（Screen Recording 权限依赖）、[12 · 测试策略](./12-testing-permission-gated.md)（权限敏感测试 gating）

---

*Last verified against Peekaboo @ `2a523301b0addfe2ce61959d0152e28435491a74`*
