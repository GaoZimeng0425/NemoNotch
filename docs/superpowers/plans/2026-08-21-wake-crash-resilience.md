# Wake-Crash Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除唤醒时窗口重建与 AppKit 重配的时序交错(L1),为不可归零的平台层崩溃提供 ≤3s 信号处理器自愈 + 3 次熔断(L2),并让每次唤醒留下可诊断快照(L3)。

**Architecture:** 新增 `WakeObserver`(单例,订阅 didWake,提供 `quietAfter` 静默期 + 唤醒诊断日志)与 `CrashRelaunch`(enum,启动时读熔断标记、安装 async-signal-safe 致命信号处理器、posix_spawn 延迟重启脚本)。两个既有屏幕参数通知回调改为"取消-重调度"去抖模式,重建逻辑本身零改动。

**Tech Stack:** Swift 6 / AppKit(sigaction、posix_spawn、sysctl、NSWorkspace 通知)/ Swift Testing。

**Spec:** `docs/superpowers/specs/2026-08-21-wake-crash-resilience-design.md`(d60381f)

## Global Constraints

- 只改 macOS 目标;Swift 6 严格并发 — 所有 AppKit 触碰必须在 `@MainActor`。
- 工程为 Xcode 16 文件系统同步组(`PBXFileSystemSynchronizedRootGroup` 已确认):新建 `.swift` 文件放进 `NemoNotch/` 对应目录即可,**不要手工编辑 project.pbxproj**。
- 日志走 `LogService`,category 用模块名(`"WakeObserver"`、`"CrashRelaunch"`、`"NotchCoordinator"`、`"CompletionFlash"`);生命周期 `.info`,调度细节 `.debug`,异常 `.warn`。
- UI 字符串必须进 String Catalog,且只通过 `python3 scripts/xcstrings.py set ...` 写入(手工 JSON 会被 pre-commit 钩子重排,但用脚本生成最小 diff)。
- 信号处理器内**只允许** `open/write/close/posix_spawn/signal/raise` 与对已初始化静态存储的读写;零 ObjC、零 malloc、零格式化。
- Git Flow:一切提交在 `feature/crash-resilience`,禁止直接提交 main;合并回 develop 用 `--no-ff`。
- 提交身份保持仓库现状(GaoZimeng / gaozimeng0425@gmail.com),不要动 git config。

---

### Task 1: 分支 + 常量 + ScreenRebuildPolicy 纯函数(TDD)

**Files:**
- Create: `NemoNotch/Notch/WakeObserver.swift`(本任务先只放纯函数,后续任务扩充)
- Modify: `NemoNotch/Helpers/Constants.swift`(锚点:`static let hoverReopenSuppression: TimeInterval = 0.35` 行后)
- Test: `NemoNotchTests/ScreenRebuildPolicyTests.swift`

**Interfaces:**
- Produces: `ScreenRebuildPolicy.delay(now: Date, quietAfter: Date, debounce: TimeInterval) -> TimeInterval`(static,纯函数,无 actor 隔离);`NotchConstants.screenRebuildDebounce = 0.5`、`NotchConstants.wakeBackoff = 2.5`。Task 3/4 依赖这三个名字。

- [ ] **Step 1: 创建分支**

```bash
git checkout develop && git pull --ff-only && git checkout -b feature/crash-resilience
```

- [ ] **Step 2: 写失败测试**

创建 `NemoNotchTests/ScreenRebuildPolicyTests.swift`:

```swift
import Foundation
@testable import NemoNotch
import Testing

struct ScreenRebuildPolicyTests {
    @Test func quietAfterInPastReturnsDebounce() {
        let delay = ScreenRebuildPolicy.delay(
            now: Date(timeIntervalSince1970: 100),
            quietAfter: Date(timeIntervalSince1970: 90),
            debounce: 0.5
        )
        #expect(delay == 0.5)
    }

    @Test func quietAfterFutureExtendsDelay() {
        let delay = ScreenRebuildPolicy.delay(
            now: Date(timeIntervalSince1970: 100),
            quietAfter: Date(timeIntervalSince1970: 102),
            debounce: 0.5
        )
        #expect(delay == 2.0)
    }

    @Test func nearQuietAfterStillAtLeastDebounce() {
        let delay = ScreenRebuildPolicy.delay(
            now: Date(timeIntervalSince1970: 100),
            quietAfter: Date(timeIntervalSince1970: 100.2),
            debounce: 0.5
        )
        #expect(delay == 0.5)
    }
}
```

- [ ] **Step 3: 运行确认失败**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/ScreenRebuildPolicyTests 2>&1 | tail -5
```

Expected: FAIL,`cannot find 'ScreenRebuildPolicy' in scope`。

- [ ] **Step 4: 最小实现**

创建 `NemoNotch/Notch/WakeObserver.swift`:

```swift
import Foundation

/// 屏幕重建的触发时机策略 —— 纯函数,可单测。
///
/// 冷事件(插拔显示器)只吃 `debounce` 的去抖;热事件(唤醒)额外吃到
/// `quietAfter`(WakeObserver 在 didWake 时设为 now + wakeBackoff),
/// 确保 rebuild 不落进 AppKit 唤醒重配的窗口(2026-08-19 崩溃发生在
/// 开盖后 ~1.4s)。
enum ScreenRebuildPolicy {
    static func delay(now: Date, quietAfter: Date, debounce: TimeInterval) -> TimeInterval {
        max(debounce, quietAfter.timeIntervalSince(now))
    }
}
```

在 `NemoNotch/Helpers/Constants.swift` 的 `hoverReopenSuppression` 行后追加:

```swift
    /// Debounce that coalesces didChangeScreenParametersNotification bursts into
    /// one deferred window rebuild (cold path: monitor plug/unplug).
    static let screenRebuildDebounce: TimeInterval = 0.5
    /// After wake, screen rebuilds wait at least this long past the wake event —
    /// AppKit is itself mid-reconfiguration (the 2026-08-19 wake crash fired
    /// ~1.4s after lid-open).
    static let wakeBackoff: TimeInterval = 2.5
```

- [ ] **Step 5: 运行确认通过**

同 Step 3 命令。Expected: PASS,`Test Suite 'ScreenRebuildPolicyTests' passed`(3 tests)。

- [ ] **Step 6: 提交**

```bash
git add NemoNotch/Notch/WakeObserver.swift NemoNotch/Helpers/Constants.swift NemoNotchTests/ScreenRebuildPolicyTests.swift
git commit -m "feat(resilience): screen rebuild delay policy + tunables"
```

---

### Task 2: MainThreadProbe 快照函数提取 + WakeObserver 本体(L3)

**Files:**
- Modify: `NemoNotch/Services/MainThreadProbe.swift`(提取 `recordSlowRunloop` 内的窗口格式化为静态函数,~行 117–122)
- Modify: `NemoNotch/Notch/WakeObserver.swift`(追加 WakeObserver 类)

**Interfaces:**
- Consumes: `NotchConstants.wakeBackoff`(Task 1)。
- Produces: `MainThreadProbe.windowSnapshotLines() -> [String]`(`@MainActor static`);`WakeObserver.shared`、`WakeObserver.quietAfter: Date`(默认 `.distantPast`)、`WakeObserver.start()`(幂等)。Task 3/4/6 依赖。

- [ ] **Step 1: 提取快照函数**

在 `MainThreadProbe.swift` 中,把 `recordSlowRunloop` 里的窗口快照段:

```swift
        // 窗口快照:看哪个窗口在疯布局。
        let windows = NSApp?.windows ?? []
        let windowSnap = windows.map { win -> String in
            let cv = win.contentView
            let cvSize = cv.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "nil"
            return "\(type(of: win)) title=\"\(win.title)\" frame=\(Int(win.frame.width))x\(Int(win.frame.height)) contentView=\(cvSize) visible=\(win.isVisible)"
        }.joined(separator: "\n  ")
```

替换为:

```swift
        // 窗口快照:看哪个窗口在疯布局。
        let windowLines = Self.windowSnapshotLines()
        let windowSnap = windowLines.joined(separator: "\n  ")
```

并把紧随其后的 `windows (\(windows.count)):` 改为 `windows (\(windowLines.count)):`(该行在 `LogService.warn` 的多行字符串里)。然后在 `MainThreadProbe` 内新增:

```swift
    /// 单行窗口描述。WakeObserver 的唤醒诊断与慢 runloop 快照共用同一格式,
    /// 让"崩溃前 MainThreadProbe 抓到的"与"唤醒时 WakeObserver 抓到的"能逐行对照。
    @MainActor
    static func windowSnapshotLines() -> [String] {
        let windows = NSApp?.windows ?? []
        return windows.map { win -> String in
            let cv = win.contentView
            let cvSize = cv.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" } ?? "nil"
            return "\(type(of: win)) title=\"\(win.title)\" frame=\(Int(win.frame.width))x\(Int(win.frame.height)) contentView=\(cvSize) visible=\(win.isVisible)"
        }
    }
```

- [ ] **Step 2: 追加 WakeObserver 类**

在 `WakeObserver.swift` 顶部补 `import AppKit`,文件末尾追加:

```swift
/// 唤醒观察者:L1 的「静默期」与 L3 的「唤醒诊断快照」共用这一个 didWake 订阅。
@MainActor
final class WakeObserver {
    static let shared = WakeObserver()

    /// 屏幕重建不得早于该时刻。唤醒时被推后 `wakeBackoff`;其余时间为 distantPast。
    private(set) var quietAfter: Date = .distantPast
    private var observer: Any?

    /// 幂等;由 AppDelegate 在启动时调用。
    func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        LogService.info("WakeObserver started", category: "WakeObserver")
    }

    private func handleWake() {
        quietAfter = Date().addingTimeInterval(NotchConstants.wakeBackoff)
        let lines = MainThreadProbe.windowSnapshotLines()
        let screens = NSScreen.screens.map { screen -> String in
            "displayID=\(screen.displayID) frame=\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        }
        LogService.info(
            """
            system woke — screen rebuild backoff \(NotchConstants.wakeBackoff)s
            windows (\(lines.count)):
              \(lines.joined(separator: "\n  "))
            screens (\(screens.count)):
              \(screens.joined(separator: "\n  "))
            """,
            category: "WakeObserver"
        )
    }
}
```

注:`NSScreen.displayID` 是仓库既有扩展(NotchCoordinator 已用 `\.displayID`),无需新增。

- [ ] **Step 3: 构建 + 全量测试**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED,全部既有测试 PASS(本任务无新测试;格式提取不改变 MainThreadProbe 输出)。

- [ ] **Step 4: 提交**

```bash
git add NemoNotch/Services/MainThreadProbe.swift NemoNotch/Notch/WakeObserver.swift
git commit -m "feat(resilience): WakeObserver — wake backoff + diagnostics snapshot"
```

---

### Task 3: NotchCoordinator 去抖调度

**Files:**
- Modify: `NemoNotch/Notch/NotchCoordinator.swift`(属性区 ~行 27 附近加 task 存储;`screenParametersChanged` ~行 283–290)

**Interfaces:**
- Consumes: `ScreenRebuildPolicy.delay`、`WakeObserver.shared.quietAfter`、`NotchConstants.screenRebuildDebounce`。

- [ ] **Step 1: 加任务存储属性**

在 `private var closeGraceTask: Task<Void, Never>?` 行后加:

```swift
    /// 去抖后的屏幕重建任务(screenParametersChanged 连发时取消-重调度,合并为一次)。
    private var screenRebuildTask: Task<Void, Never>?
```

- [ ] **Step 2: 重写处理器**

把:

```swift
    @objc private func screenParametersChanged() {
        notchSize = Self.resolveUnifiedNotchSize()
        rebuildSlots()
        // If the active screen disappeared mid-session, gracefully collapse.
        if let active = activeScreen, slots[active.displayID] == nil {
            activeScreen = nil
            status = .closed
        }
    }
```

替换为:

```swift
    @objc private func screenParametersChanged() {
        // 不在通知回调里同步动窗口:唤醒时该通知于 AppKit 自身重配中途发出且可能
        // 连发,我们的 close/rebuild 与它的状态栏重建交错正是 2026-08-19 崩溃的
        // 诱因面。连发合并为一次,延迟取 max(debounce, 唤醒静默期剩余)。
        screenRebuildTask?.cancel()
        let delay = ScreenRebuildPolicy.delay(
            now: Date(),
            quietAfter: WakeObserver.shared.quietAfter,
            debounce: NotchConstants.screenRebuildDebounce
        )
        screenRebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.notchSize = Self.resolveUnifiedNotchSize()
            self.rebuildSlots()
            // If the active screen disappeared mid-session, gracefully collapse.
            if let active = self.activeScreen, self.slots[active.displayID] == nil {
                self.activeScreen = nil
                self.status = .closed
            }
        }
        LogService.debug(
            "screen params changed — rebuild deferred \(String(format: "%.2f", delay))s",
            category: "NotchCoordinator"
        )
    }
```

注:`init` 里的首次 `rebuildSlots()` **保持不动**(冷路径,窗口须先于首帧存在)。`Task {}` 从 `@MainActor` 上下文继承主执行器,`WakeObserver.shared` 访问安全。

- [ ] **Step 3: 构建 + 全量测试**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED,测试全绿。

- [ ] **Step 4: 提交**

```bash
git add NemoNotch/Notch/NotchCoordinator.swift
git commit -m "feat(resilience): defer notch slot rebuild off the screen-params sync path"
```

---

### Task 4: CompletionFlashWindowController 去抖调度

**Files:**
- Modify: `NemoNotch/Notch/CompletionFlashWindow.swift`(属性区 ~行 32 后加 task 存储;observer 闭包 ~行 39–44)

**Interfaces:**
- Consumes: 与 Task 3 相同。

- [ ] **Step 1: 加任务存储属性**

在 `private nonisolated(unsafe) var observer: Any?` 行后加:

```swift
    private var rebuildTask: Task<Void, Never>?
```

- [ ] **Step 2: 重写 observer 闭包**

把:

```swift
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
```

替换为:

```swift
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rebuildTask?.cancel()
                let delay = ScreenRebuildPolicy.delay(
                    now: Date(),
                    quietAfter: WakeObserver.shared.quietAfter,
                    debounce: NotchConstants.screenRebuildDebounce
                )
                self.rebuildTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    self?.rebuild()
                }
            }
        }
```

注:`init` 里的首次 `rebuild()` **保持不动**。

- [ ] **Step 3: 构建 + 全量测试**

同 Task 3 Step 3 命令。Expected: BUILD SUCCEEDED,测试全绿。

- [ ] **Step 4: 提交**

```bash
git add NemoNotch/Notch/CompletionFlashWindow.swift
git commit -m "feat(resilience): debounce completion-flash overlay rebuild on screen params"
```

---

### Task 5: CrashRelaunchDecision 纯函数(TDD)

**Files:**
- Create: `NemoNotch/Services/CrashRelaunch.swift`(本任务先放决策类型)
- Test: `NemoNotchTests/CrashRelaunchDecisionTests.swift`

**Interfaces:**
- Produces: `CrashRelaunchDecision{shouldInstall: Bool, nextCount: Int, trippedBreaker: Bool}` 与 `CrashRelaunchDecision.decide(markerCount: Int?, markerAge: TimeInterval?, loopLimit: Int = 3, loopWindow: TimeInterval = 600) -> CrashRelaunchDecision`。Task 6 依赖。

- [ ] **Step 1: 写失败测试**

创建 `NemoNotchTests/CrashRelaunchDecisionTests.swift`:

```swift
import Foundation
@testable import NemoNotch
import Testing

struct CrashRelaunchDecisionTests {
    @Test func noMarkerInstallsAtOne() {
        let d = CrashRelaunchDecision.decide(markerCount: nil, markerAge: nil)
        #expect(d.shouldInstall && d.nextCount == 1 && !d.trippedBreaker)
    }

    @Test func recentCountBelowLimitInstallsIncremented() {
        let d = CrashRelaunchDecision.decide(markerCount: 2, markerAge: 60)
        #expect(d.shouldInstall && d.nextCount == 3 && !d.trippedBreaker)
    }

    @Test func recentCountAtLimitTripsBreakerAndResets() {
        let d = CrashRelaunchDecision.decide(markerCount: 3, markerAge: 60)
        #expect(!d.shouldInstall && d.trippedBreaker && d.nextCount == 1)
    }

    @Test func countAboveLimitAlsoTrips() {
        let d = CrashRelaunchDecision.decide(markerCount: 7, markerAge: 60)
        #expect(!d.shouldInstall && d.trippedBreaker)
    }

    @Test func staleMarkerStartsFresh() {
        let d = CrashRelaunchDecision.decide(markerCount: 3, markerAge: 3600)
        #expect(d.shouldInstall && d.nextCount == 1 && !d.trippedBreaker)
    }

    @Test func zeroCountTreatedAsFresh() {
        let d = CrashRelaunchDecision.decide(markerCount: 0, markerAge: 10)
        #expect(d.shouldInstall && d.nextCount == 1 && !d.trippedBreaker)
    }
}
```

- [ ] **Step 2: 运行确认失败**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/CrashRelaunchDecisionTests 2>&1 | tail -5
```

Expected: FAIL,`cannot find 'CrashRelaunchDecision' in scope`。

- [ ] **Step 3: 最小实现**

创建 `NemoNotch/Services/CrashRelaunch.swift`:

```swift
import Foundation

/// 熔断判定 —— 纯函数,输入启动时读到的标记状态(count + mtime 距今秒数)。
///
/// - 无标记 / 标记过期 / count<=0 → 全新周期,装处理器,计数从 1 起;
/// - 近期且 count < limit → 装处理器,计数 +1(处理器预写);
/// - 近期且 count >= limit → 熔断:本次不装,重置计数(下次手动启动重新来)。
struct CrashRelaunchDecision: Equatable {
    let shouldInstall: Bool
    /// 处理器将写入标记文件的计数(或熔断重置后的 1)。
    let nextCount: Int
    /// true = 连续崩溃已达上限,本次运行不装自愈。
    let trippedBreaker: Bool

    static func decide(
        markerCount: Int?,
        markerAge: TimeInterval?,
        loopLimit: Int = 3,
        loopWindow: TimeInterval = 600
    ) -> CrashRelaunchDecision {
        guard let count = markerCount, count > 0,
              let age = markerAge, age < loopWindow else {
            return CrashRelaunchDecision(shouldInstall: true, nextCount: 1, trippedBreaker: false)
        }
        if count >= loopLimit {
            return CrashRelaunchDecision(shouldInstall: false, nextCount: 1, trippedBreaker: true)
        }
        return CrashRelaunchDecision(shouldInstall: true, nextCount: count + 1, trippedBreaker: false)
    }
}
```

- [ ] **Step 4: 运行确认通过**

同 Step 2 命令。Expected: PASS(6 tests)。

- [ ] **Step 5: 提交**

```bash
git add NemoNotch/Services/CrashRelaunch.swift NemoNotchTests/CrashRelaunchDecisionTests.swift
git commit -m "feat(resilience): crash-relaunch breaker decision (pure)"
```

---

### Task 6: CrashRelaunch 信号机制 + AppDelegate 接线

**Files:**
- Modify: `NemoNotch/Services/CrashRelaunch.swift`(追加 `enum CrashRelaunch` 与顶层处理器函数)
- Modify: `NemoNotch/NemoNotchApp.swift`(`applicationDidFinishLaunching`,~行 138 `MainThreadProbe.shared.install()` 之后)

**Interfaces:**
- Consumes: `CrashRelaunchDecision`(Task 5)、`UITestMode.isActive`。
- Produces: `CrashRelaunch.setup()`(static,幂等语义:每次进程一次)。

- [ ] **Step 1: 追加信号机制**

在 `CrashRelaunch.swift` 顶部补 `import Darwin`,文件末尾追加:

```swift
/// 崩溃自愈:致命信号处理器 + 延迟重启脚本,3 次熔断(Task 5 的决策类型)。
///
/// 处理器内只做 async-signal-safe 操作:open/write/close、posix_spawn、
/// signal、raise。路径与载荷全部在 setup() 预构建 —— 处理器内零 ObjC、
/// 零 malloc、零字符串格式化。时间戳语义由标记文件的 mtime 承担,处理器
/// 无需写时间。exec 后子进程不继承我们的处理器(自定义 handler 不会跨
/// exec 存活),故无需 POSIX_SPAWN_SETSIGDEF。
enum CrashRelaunch {
    static let markerURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".NemoNotch")
        .appendingPathComponent("crash-relaunch.count")
    static let loopLimit = 3
    static let loopWindow: TimeInterval = 600
    static let stableRun: TimeInterval = 300
    static let relaunchDelaySeconds = 1

    // 处理器可见的预构建存储(setup() 在安装处理器前全部初始化)。
    private static var payloadPtr: UnsafeMutablePointer<CChar>?
    private static var payloadLen = 0
    private static var markerPath: UnsafeMutablePointer<CChar>?
    private static var relaunchArgv: [UnsafeMutablePointer<CChar>?] = []
    private static var fired = false

    /// 进程内调用一次;`applicationDidFinishLaunching` 最前置。
    /// UITest 截图运行与调试器挂载时整体跳过。
    static func setup() {
        guard !isDebuggerAttached() else {
            LogService.info("crash-relaunch skipped — debugger attached", category: "CrashRelaunch")
            return
        }
        let count = readMarkerCount()
        let age = markerAge()
        let decision = CrashRelaunchDecision.decide(
            markerCount: count,
            markerAge: age,
            loopLimit: loopLimit,
            loopWindow: loopWindow
        )
        if decision.trippedBreaker {
            LogService.warn(
                "crash-relaunch breaker tripped (\(count ?? 0) crashes within \(Int(loopWindow / 60))min) — self-heal paused this run",
                category: "CrashRelaunch"
            )
            removeMarker()
        } else {
            if let c = count, let a = age, a < loopWindow {
                LogService.warn(
                    "previous run died by fatal signal (count=\(c)) — self-healed relaunch",
                    category: "CrashRelaunch"
                )
            }
            payloadPtr = strdup("\(decision.nextCount)\n")
            payloadLen = "\(decision.nextCount)\n".utf8.count
            markerPath = strdup(markerURL.path)
            let command = "sleep \(relaunchDelaySeconds); open -b \(Bundle.main.bundleIdentifier ?? "com.nemo.BrightnessApp.NemoNotch")"
            relaunchArgv = [strdup("/bin/sh"), strdup("-c"), strdup(command), nil]
            installHandlers()
            LogService.info("crash-relaunch armed (nextCount=\(decision.nextCount))", category: "CrashRelaunch")
        }
        // 稳定运行清零:健康跑满 stableRun 删标记,下个周期再崩仍会自愈。
        DispatchQueue.main.asyncAfter(deadline: .now() + stableRun) {
            removeMarker()
            LogService.info("crash-relaunch marker cleared after stable run", category: "CrashRelaunch")
        }
    }

    private static func readMarkerCount() -> Int? {
        guard let text = try? String(contentsOf: markerURL, encoding: .utf8) else { return nil }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func markerAge() -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: markerURL.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(mtime)
    }

    private static func removeMarker() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    private static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        return sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0
            && (info.kp_proc.p_flag & P_TRACED) != 0
    }

    private static func installHandlers() {
        var action = sigaction()
        sigemptyset(&action.sa_mask)
        action.__sigaction_u.__sa_handler = nemonotchFatalSignalHandler
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT] {
            sigaction(sig, &action, nil)
        }
    }
}

/// 顶层 C 兼容处理器 —— 不能捕获任何上下文,只能访问已初始化的静态存储。
private func nemonotchFatalSignalHandler(_ sig: Int32) {
    // async-signal-safe only。
    if CrashRelaunch.fired { signal(sig, SIG_DFL); raise(sig); return }
    CrashRelaunch.fired = true
    if let path = CrashRelaunch.markerPath, let payload = CrashRelaunch.payloadPtr {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        if fd >= 0 {
            _ = write(fd, payload, CrashRelaunch.payloadLen)
            close(fd)
        }
    }
    var pid: pid_t = 0
    _ = CrashRelaunch.relaunchArgv.withUnsafeBufferPointer { buf in
        posix_spawn(&pid, "/bin/sh", nil, nil, buf.baseAddress, nil)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
```

注:静态存储的访问需要它们对文件内可见 — 把 `enum CrashRelaunch` 里的 `private static var` 五个存储改为 `fileprivate`(处理器要读写)。实现时直接声明为 `fileprivate static var`。

- [ ] **Step 2: AppDelegate 接线**

在 `NemoNotch/NemoNotchApp.swift` 的 `MainThreadProbe.shared.install()` 行后追加:

```swift
        // 崩溃自愈最前置:后续任何初始化路径崩溃都能自愈(带 3 次熔断)。
        if !UITestMode.isActive { CrashRelaunch.setup() }

        // 唤醒观察者:屏幕重建静默期(L1)+ 唤醒诊断快照(L3)。
        if !UITestMode.isActive { WakeObserver.shared.start() }
```

- [ ] **Step 3: 构建 + 全量测试**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED,测试全绿(测试 runner 无调试器语义差异;`isDebuggerAttached` 在 `xcodebuild test` 下可能为真 → setup 跳过,属预期行为)。

- [ ] **Step 4: 手动冒烟(一次性,验证自愈路径)**

```bash
pkill -x NemoNotch; sleep 1; open -b com.nemo.BrightnessApp.NemoNotch; sleep 3
kill -SEGV $(pgrep -x NemoNotch)
sleep 4; pgrep -x NemoNotch && echo "RELIVED ✓" || echo "NOT RELIVED ✗"
cat ~/.NemoNotch/crash-relaunch.count   # 期望: 1
ls ~/Library/Logs/DiagnosticReports/ | grep NemoNotch | tail -1   # 期望: 新崩溃报告仍在
```

Expected: 进程 ≤3s 回来;count 文件为 1;崩溃报告存在。清理:`rm ~/.NemoNotch/crash-relaunch.count`。

- [ ] **Step 5: 提交**

```bash
git add NemoNotch/Services/CrashRelaunch.swift NemoNotch/NemoNotchApp.swift
git commit -m "feat(resilience): fatal-signal self-heal with breaker + launch wiring"
```

---

### Task 7: 菜单「重启 NemoNotch」项 + 本地化

**Files:**
- Modify: `NemoNotch/Notch/MenuBar/AppSection.swift`
- Modify: `NemoNotch/Resources/Localizable.xcstrings`(经脚本)

**Interfaces:**
- Consumes: 无(纯 UI)。

- [ ] **Step 1: 加字符串目录项**

```bash
python3 scripts/xcstrings.py set NemoNotch/Resources/Localizable.xcstrings menu.restart_app --en "Restart NemoNotch" --zh "重启 NemoNotch"
```

- [ ] **Step 2: 加菜单项**

在 `AppSection.swift` 的 `Button("menu.about")` 闭合后、`Button("menu.quit")` 之前插入:

```swift
        Button("menu.restart_app") {
            AppRestart.request()
        }
```

并在文件末尾追加:

```swift
/// 菜单级手动重启:先拉起一个等待脚本(轮询本进程退出,上限 30s —— 消化
/// KeepAwake 退出还原可能延迟退出),再 terminate。
enum AppRestart {
    static func request() {
        let command = "for i in $(seq 1 60); do pgrep -x NemoNotch >/dev/null || break; sleep 0.5; done; open -b com.nemo.BrightnessApp.NemoNotch"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        do {
            try task.run()
        } catch {
            LogService.error("restart script failed to launch: \(error.localizedDescription)", category: "AppRestart")
        }
        NSApplication.shared.terminate(nil)
    }
}
```

注:`AppSection.swift` 顶部需补 `import AppKit`(现有只 `import SwiftUI`;`NSApplication`/`Process` 需要)。若编译器报重定义,则确认文件确实只 import 了 SwiftUI 再加。

- [ ] **Step 3: 构建 + 全量测试**

同 Task 6 Step 3 命令。Expected: BUILD SUCCEEDED,测试全绿;pre-commit 会规范化 xcstrings(无需手工干预)。

- [ ] **Step 4: 提交**

```bash
git add NemoNotch/Notch/MenuBar/AppSection.swift NemoNotch/Resources/Localizable.xcstrings
git commit -m "feat(resilience): manual restart menu item"
```

---

### Task 8: 文档同步

**Files:**
- Modify: `README.md`、`README_CN.md`、`CLAUDE.md`
- Modify: `docs/macos/macos-cookbook.md`(**先检查符号链接存在**:`ls docs/macos/macos-cookbook.md`;不存在则跳过并记入 PR 描述)

- [ ] **Step 1: README 增补(两份)**

在特性列表(与 Keep Awake / 稳定性相关的小节,按两份文件既有结构插入)加一条:

- EN:`- Crash self-healing: auto-restarts within ~3s after a fatal crash (3-strike breaker), and defers window rebuilds off the wake path.`
- CN:`- 崩溃自愈:致命崩溃后 ~3 秒内自动重启(连续 3 次熔断),唤醒期间窗口重建自动退避。`

- [ ] **Step 2: CLAUDE.md 增补**

在 "Keep Awake with the Lid Closed" 章节后新增小节:

```markdown
### Crash Resilience

`WakeObserver` (`NemoNotch/Notch/WakeObserver.swift`, singleton started by AppDelegate) owns everything wake-adjacent: on `NSWorkspace.didWakeNotification` it sets `quietAfter = now + NotchConstants.wakeBackoff (2.5s)` and logs a `.info` diagnostics snapshot (`MainThreadProbe.windowSnapshotLines()` + screen list). Both screen-parameters handlers (`NotchCoordinator.screenParametersChanged`, `CompletionFlashWindowController`'s observer) coalesce bursts and schedule their rebuild at `ScreenRebuildPolicy.delay = max(screenRebuildDebounce 0.5s, quietAfter − now)` — never synchronously in the notification callback, because at wake that notification fires mid-AppKit-reconfiguration (the 2026-08-19 SIGSEGV: an over-released `NSStatusBarWindow` detonated at autorelease-pool drain ~1.4s after lid-open). Initial builds in `init` stay synchronous (cold path).

`CrashRelaunch` (`NemoNotch/Services/CrashRelaunch.swift`) self-heals fatal crashes: a `sigaction` handler for SIGSEGV/SIGBUS/SIGILL/SIGABRT that is async-signal-safe ONLY (open/write/close, posix_spawn, signal, raise — every path/payload/argv prebuilt in `setup()`, timestamps carried by the marker file's mtime, no formatting in-handler). It spawns `sh -c "sleep 1; open -b <bundle>"` then re-raises with `SIG_DFL` so macOS still writes the crash report. Breaker: marker `~/.NemoNotch/crash-relaunch.count` (pure decision `CrashRelaunchDecision`, unit-tested) — 3 crashes within 10min pauses self-heal for the run; a stable 5min run clears the marker. Skipped under `UITestMode` and when a debugger is attached (`P_TRACED` via sysctl). Crashes never run the KeepAwake quit-restore; the existing startup reconciliation owns the leftover.
```

- [ ] **Step 3: cookbook 条目(符号链接在时)**

在 macos-cookbook.md 的窗口/进程相关章节(§5 或 §12,按文件实际结构)加条目,标题 `Signal-handler crash self-heal`:

```markdown
- **Signal-handler crash self-heal** (`NemoNotch/Services/CrashRelaunch.swift`): when the root cause is a platform-level over-release you cannot fix (wake-time `NSStatusBarWindow` SIGSEGV), guarantee recovery speed instead. Handler discipline: only `open/write/close`, `posix_spawn`, `signal`, `raise`; prebuild path/payload/argv at startup (strdup) so the handler does zero ObjC/malloc/formatting — a top-level `fileprivate func` converts to `@convention(c)` where a static-method reference may not. Use the marker file's **mtime as the crash timestamp** (no `strftime` in-handler). After `posix_spawn` re-raise with `SIG_DFL` so the OS crash report is still produced. No `POSIX_SPAWN_SETSIGDEF` needed: custom handlers do not survive `exec`. Gate installation with `P_TRACED` (sysctl `kinfo_proc.kp_proc.p_flag`) so debug builds behave normally. See spec `docs/superpowers/specs/2026-08-21-wake-crash-resilience-design.md`.
```

- [ ] **Step 4: 提交**

```bash
git add README.md README_CN.md CLAUDE.md
git commit -m "docs: crash resilience — wake backoff, self-heal, diagnostics"
# cookbook 若在:
git add docs/macos/macos-cookbook.md && git commit --amend --no-edit
```

---

### Task 9: 全量验收 + 合并

- [ ] **Step 1: 全量单测**

```bash
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: 全绿。

- [ ] **Step 2: 手动验收清单(spec 验收节)**

外接显示器在位,执行并记录结果:

1. `kill -SEGV <pid>` ×3(间隔 <10min):前 3 次各 ≤3s 恢复;第 4 次 `kill -SEGV` 后**不**再自愈,日志有 breaker `.warn`;等 5 分钟(或删 count 文件)后恢复自愈。
2. 合盖 → 10s → 开盖,×10:无崩溃;每次唤醒日志有 `WakeObserver` 快照(`~/.NemoNotch/logs/` 最新文件 grep `system woke`)。
3. 系统菜单 → 睡眠 → 唤醒,×10:同上,无窗口丢失(刘海面板 / 菜单栏图标 / 完成闪光覆盖窗)。
4. 热插拔显示器 ×5:notch 窗口 ≤1.5s 出现在新屏(去抖无感),移除屏幕后对应窗口消失。
5. 菜单 → 重启 NemoNotch:应用退出并在 ~1–2s 回来(KeepAwake 若开启,退出还原授权框期间重启脚本会等待)。

- [ ] **Step 3: 合并回 develop**

```bash
git checkout develop && git merge --no-ff feature/crash-resilience -m "Merge branch 'feature/crash-resilience' into develop"
```

(本机未装 githooks 时 `sh .githooks/install.sh` 先装上;merge guard 会校验分支名。)

- [ ] **Step 4: 收尾记录**

在 PR/merge 描述里记录:验收清单各项结果、cookbook 符号链接是否存在、spec 路径。

---

## Self-Review 记录

- **Spec coverage**:L1(Task 1/3/4)、L2(Task 5/6/7)、L3(Task 2)、测试与验收(Task 1/5 单测 + Task 6 冒烟 + Task 9 清单)、文档义务(Task 8)、分支流程(Task 1/9)—— spec 各节均有对应任务。
- **Placeholder scan**:无 TBD/TODO;每个代码步骤均含完整代码。
- **Type consistency**:`ScreenRebuildPolicy.delay(now:quietAfter:debounce:)` 在 Task 1 定义、Task 3/4 消费一致;`WakeObserver.shared.quietAfter`/`start()` Task 2 定义、Task 3/4/6 消费一致;`CrashRelaunchDecision.decide(markerCount:markerAge:loopLimit:loopWindow:)` Task 5 定义、Task 6 消费一致(传 `loopLimit: loopLimit, loopWindow: loopWindow` 显式对齐)。
