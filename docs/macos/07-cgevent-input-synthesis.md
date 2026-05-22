---
summary: 'Synthesize realistic keyboard and mouse input via CGEvent: log-normal timing, wind-gravity mouse trajectories, modifier safety, and Electron/Chrome/VSCode non-native targets.'
read_when:
  - 'implementing automated input injection that needs to appear human-like'
  - 'making CGEvent-based input reliably perceived by target applications including Electron, Chrome, and VSCode'
  - 'debugging dropped keystrokes, modifier leakage, or silent failures in non-native app targets'
---

# 07 · CGEvent 拟真输入

## TL;DR

macOS 的 `CGEvent` API 可以在软件层合成键盘与鼠标事件,但"发出去"不等于"被目标感知"。Peekaboo 在原始合成之上叠加了两层拟真:打字节律用**对数正态分布**模拟击键间隔(150 WPM → ~80 ms 基础延迟,±30% 对数正态抖动),鼠标路径用**风/重力积分 + 可控超调**模拟手部轨迹。整个输入链优先走 **AX `setValue`**——仅当 AX 路径不可用时才降级到 CGEvent 合成——这一分级决策使大多数原生 Cocoa 控件既快速又可靠。对于 Electron / Chromium 系(VSCode、Discord、Slack 等)**非原生**目标,主进程↔渲染进程 IPC 以及 Chromium 在 session 层安装的事件 filter 会让 `.cgSessionEventTap` 失效;Peekaboo 通过 AX `setValue` 优先、click-focus 聚焦、`.cghidEventTap` + ≥1 ms 间隔三级降级应对。所有随机源均可注入,测试时固定种子即可换取确定性。

## Peekaboo 在哪里实现

- 模块:`PeekabooAutomationKit`
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/SyntheticInputDriver.swift:6` — `SyntheticInputDriving` 协议定义;`SyntheticInputDriver:20` 是薄壳包装,将 AXorcist 的低层调用与上层服务解耦
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/TypeService+TypingCadence.swift:55` — `HumanTypingContext`:对数正态采样、标点乘数、词间思考停顿
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/GestureService+Paths.swift:56` — `HumanMousePathGenerator`:风/重力积分、超调、微抖动
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/BackgroundInputDriver.swift:11` — `BackgroundInputDriver`:向目标 pid 路由事件而不扰动前台;`BackgroundInputDriver.swift:61` 的私有 `post(_:to:)` 优先走 `SLEventPostToPid`(SkyLight 私有),失败时回退 `postToPid`
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/TypeService+SpecialKeys.swift:79` — `TypeServiceSpecialKeyMapping.postKey`:特殊键合成,1 ms 间隔已内置
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/HotkeyService.swift:138` — `performSyntheticHotkey`:组合键合成,`defer` 保证 keyUp 一定执行
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/TypeService.swift:114` — AX 优先入口:`performActionType` 先尝试 `trySetText`;失败后 `performSyntheticType:132` 降级到 CGEvent
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/ElementDetectionWindowResolver.swift:102` — Chrome 多进程 AX 超时特殊处理
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/ElementDetectionService.swift:215` — 第一次遍历结果稀疏时触发 web focus fallback(针对 Chromium/Tauri 内容隐藏问题)
- 相关 docs:`docs/human-typing.md`、`docs/human-mouse-move.md`

## 设计动机(Why)

自动化测试和 AI agent 驱动 UI 时,目标应用有四类常见障碍:

1. **速率检测** — 高频无间隔事件被识别为机器;部分富文本编辑器内部有事件队列,零间隔会丢字符。解决方案:对数正态间隔,最小 1 ms(特殊键路径已内置)。

2. **修饰键残留** — 若 `shift`/`cmd` 按下后未被显式抬起,后续输入会意外带修饰符,表现为选中、删除等副作用。解决方案:`HotkeyService.performSyntheticHotkey` 用 `defer` + `keyUpPosted` 标志确保 keyUp 一定发送(`HotkeyService.swift:141-146`)。

3. **后台投递失效** — `CGEvent.post(tap: .cghidEventTap)` 走全局 HID 管道,需要前台焦点;向后台进程投递必须改用 `event.postToPid(pid)` 或私有 `SLEventPostToPid`,并设置 `eventTargetUnixProcessID`、`windowID` 等路由字段(`BackgroundInputDriver.swift:67-82`)。

4. **非原生(Electron/Chromium)多进程架构** — Electron/Chromium 在 **session 层**(`CGSessionEventTapLocation`)安装 event filter,过滤来自外部进程的合成事件。渲染进程与主进程是独立的 macOS 进程,`postToPid(主进程 pid)` 的事件无法抵达渲染进程处理输入的实际 run loop。AX 树代理不完整:很多 input field 不暴露 `AXValue`、不实现 `AXSetValue`,或隐藏在 `AXWebArea` 内。`ElementDetectionWindowResolver.swift:102` 对此加了超时保护;`ElementDetectionService.swift:215` 检测稀疏结果并触发 web focus fallback。

## 核心模式(Pattern)

### 1 · `CGEvent.post(tap:)` vs `CGEvent.postToPid()` vs `SLEventPostToPid`

| 场景 | 推荐方式 | 注意 |
|------|---------|------|
| 目标 app 已在前台 | `event.post(tap: .cghidEventTap)` | 最兼容,走标准 HID 栈 |
| 目标 app 在后台 | `event.postToPid(pid)` | 需设置 `eventTargetUnixProcessID`、`windowID` 等路由字段 |
| 后台且需最高可靠性 | `SLEventPostToPid`(SkyLight 私有)→ 失败时回退 `postToPid` | 见 `BackgroundInputDriver.post(_:to:)`;私有 API,Mac App Store 不可用 |
| Electron/Chrome 渲染进程 | AX `setValue` 优先;AX 不可用时用 `.cghidEventTap` + 先 click-focus | 不要用 `postToPid` 主进程;详见非原生环境节 |

`BackgroundInputDriver` 的私有 `post` 方法封装了双路逻辑:

```swift
// BackgroundInputDriver.swift:61-65
private static func post(_ event: CGEvent, to pid: pid_t) {
    if !SkyLightPerPidEventPost.post(event, to: pid) {
        event.postToPid(pid)
    }
}
```

路由字段必须在 `post` 之前 stamp,否则事件到达目标进程但会被丢弃到错误的窗口:

```swift
// BackgroundInputDriver.swift:67-82
private static func stampRoutingFields(
    on event: CGEvent, at point: CGPoint, targetProcessIdentifier: pid_t)
{
    event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetProcessIdentifier))
    // windowID / mouseEventWindowUnderMousePointer 也需要填写
    guard let windowID = self.windowID(containing: point, targetProcessIdentifier: targetProcessIdentifier) else {
        return
    }
    let value = Int64(windowID)
    event.setIntegerValueField(.windowID, value: value)
    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: value)
    event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: value)
}
```

### 2 · 打字节律:对数正态采样

`HumanTypingContext` 实现了完整的拟真节律(`TypeService+TypingCadence.swift:55-149`):

```swift
// TypeService+TypingCadence.swift:125-131
private mutating func sampleLogNormal() -> TimeInterval {
    let sigma = Constants.logNormalSigma  // 0.35
    let mu = log(self.baseDelay) - 0.5 * sigma * sigma
    let gaussian = Self.generateGaussian(using: self.random)  // Box-Muller
    let value = exp(mu + sigma * gaussian)
    return max(value, self.baseDelay * 0.2)
}
```

关键参数(全部来自 `Constants`:

- `logNormalSigma = 0.35` — 形状参数;控制抖动幅度
- `baseDelay = 60.0 / (wpm * 5)` — 150 WPM → ~80 ms
- 标点/空白字符乘 `1.35`(punctuationMultiplier)
- 连续字母 digraph 乘 `0.85`(digraphMultiplier)  
- 夹到 `[baseDelay*0.25, baseDelay*3.5]`
- 每 12 个词插入 300–500 ms"思考停顿"(`thinkingWordInterval = 12`)

随机源 (`TypingCadenceRandomSource` 协议)可注入——生产路径用 `SystemTypingCadenceRandomSource`,测试路径注入固定序列。

### 3 · 鼠标路径:风/重力积分

`HumanMousePathGenerator.generate()` 在每一步叠加风、重力、阻尼、微抖动(`GestureService+Paths.swift:87-116`):

```swift
// GestureService+Paths.swift:94-103
wind.dx = (wind.dx * 0.8) + (rng.nextSignedUnit() * Self.windMagnitude(for: distanceToTarget))
wind.dy = (wind.dy * 0.8) + (rng.nextSignedUnit() * Self.windMagnitude(for: distanceToTarget))

velocity.dx = (velocity.dx + wind.dx + gravity.dx) * 0.88  // 阻尼系数
velocity.dy = (velocity.dy + wind.dy + gravity.dy) * 0.88

current.x += velocity.dx
current.y += velocity.dy
current = self.applyJitter(point: current, rng: &rng)       // ±jitterAmplitude px
```

关键参数:

- 超调概率 `overshootProbability`:距离 ≤ 120 px 不超调,超过才按概率触发
- `settleRadius`:进入后切换为真实目标坐标
- 持续时间估算:`220 + log2(dist+1)*90 + dist*0.45` ms,夹在 [250, 1600]
- 微抖动 `jitterAmplitude`(默认约 0.35 px)用可配置的 `HumanMouseProfileConfiguration`

随机源使用 `SeededGenerator`(Splitmix64 变体),种子可外部注入(`GestureService+Paths.swift:168-171`)。

### 4 · Modifier flag 正确组合与 defer 重置

`HotkeyService.performSyntheticHotkey` 展示了正确的 modifier 生命周期(`HotkeyService.swift:127-158`):

```swift
// HotkeyService.swift:138-146
keyDown.flags = plan.modifierFlags
keyUp.flags = plan.modifierFlags
keyDown.post(tap: .cghidEventTap)
var keyUpPosted = false
defer {
    if !keyUpPosted {
        keyUp.post(tap: .cghidEventTap)  // 确保 keyUp 一定执行,即使 Task.sleep 被取消
    }
}
// ... sleep(holdNanoseconds) ...
keyUp.post(tap: .cghidEventTap)
keyUpPosted = true
```

常用 modifier bits:`maskShift = 0x20000`、`maskCommand = 0x100000`、`maskAlternate = 0x80000`、`maskControl = 0x40000`。

### 5 · AX 优先,坐标兜底

`TypeService` 的主入口通过 `UIInputDispatcher` 先尝试 AX `action` 路径再 `synth` 路径(`TypeService.swift:89-111`):

```swift
// TypeService.swift:90-108  (UIInputDispatcher.run 内部的两条分支)
action: {
    // AX 路径: performActionType → trySetText(element:text:replace:)
    // 100% 可靠,绕过事件层,不受 Electron IPC 影响
    try await self.performActionType(text: text, target: target,
                                     clearExisting: clearExisting, snapshotId: snapshotId)
},
synth: {
    // CGEvent 降级路径: performSyntheticType
    // click-focus 后逐字符合成键盘事件
    try await self.performSyntheticType(text: text, target: target,
                                        clearExisting: clearExisting,
                                        typingDelay: typingDelay, snapshotId: snapshotId)
}
```

`performActionType` 的核心逻辑(`TypeService.swift:114-130`):找到 AX element → `actionInputDriver.trySetText`。找不到 element 时抛 `ActionInputError.unsupported(.missingElement)`,由 `UIInputDispatcher` 捕获并触发 `synth` 分支。

### 6 · 非原生 app 决策:三级降级表

| 优先级 | 方式 | 适用场景 | 失败信号 |
|--------|------|---------|---------|
| 1 | AX `setValue`(通过 `trySetText`) | AX 树暴露 `AXTextField`/`AXTextArea` 且实现 `AXSetValue` | 返回 `ActionInputError.unsupported` |
| 2 | AX click 聚焦 + `.cghidEventTap` + ≥1 ms 间隔 + Unicode 路径 | Electron/Chrome 中 input field 能获得 AX focus 但 AXValue 不可写 | 字符丢失、顺序乱,或 IME 候选框弹出 |
| 3 | 坐标点击聚焦 + `.cghidEventTap` | AX 树完全不可用,只知道屏幕坐标 | 依赖坐标稳定性,最脆弱 |

**绝不可做**:在 Electron/Chrome 中用 `postToPid(主进程 pid)` 投递键盘事件——事件进入主进程的 event queue 而非渲染进程,表现为完全无效果。

## 完整代码示例(Starter Code)

以下是一个可直接在 macOS 14+ 项目中使用的独立 Swift 文件,覆盖 CGEvent 输入合成的核心能力。它基于 Peekaboo 的实测实现重组,结构与 Peekaboo 保持一致但不依赖 Peekaboo 的内部模块。

**权限要求**:Accessibility(辅助功能)或 Input Monitoring。在 Xcode 项目中需在 entitlements 中添加 `com.apple.security.automation.apple-events` 或确保用户已在系统偏好中授权。

**嵌入方式**:直接将此文件加入 SPM 包的 `Sources/` 目录或 Xcode target,无额外依赖(只需 `AppKit`、`CoreGraphics`、`ApplicationServices`)。

```swift
// HumanInputDriver.swift — Starter Code for Playbook 07
// Compiles on macOS 14+.
// Requires Accessibility permission: System Settings → Privacy & Security → Accessibility.
// To embed: add this file to any macOS SPM target or Xcode target.
// No external dependencies — uses only AppKit, CoreGraphics, ApplicationServices.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Protocol (mock-friendly for testing)

public protocol HumanInputDriving: Sendable {
    func type(_ text: String, cadence: TypingCadence) async throws
    func press(keyCode: CGKeyCode, modifiers: CGEventFlags) async throws
    func move(to point: CGPoint, profile: MouseProfile) async throws
    func click(at point: CGPoint, count: Int) async throws
}

// MARK: - Error Types

public enum HumanInputError: Error, Sendable {
    /// Failed to create CGEvent (usually means CGEventSource is unavailable)
    case eventCreationFailed
    /// The target PID is not running or is 0
    case targetProcessNotRunning(pid_t)
    /// CGPreflightPostEventAccess() returned false
    case permissionDenied
}

// MARK: - Typing Cadence

public enum TypingCadence: Sendable {
    /// Fixed milliseconds between keystrokes — deterministic, good for tests
    case fixed(milliseconds: Double)
    /// Log-normal jitter around a WPM baseline — mimics human typing
    case humanWPM(Int)
}

/// Stateful log-normal sampler. Call `nextDelay(after:)` for each character.
public struct HumanTypingCadence: Sendable {
    private let baseDelay: TimeInterval
    private var previousChar: Character?
    private var wordChars = 0
    private var wordsSincePause = 0
    // Injected random source — replace with a deterministic one in tests
    private let randomSource: @Sendable () -> Double

    public init(wpm: Int, randomSource: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.baseDelay = 60.0 / (Double(max(wpm, 40)) * 5.0)
        self.randomSource = randomSource
    }

    public mutating func nextDelay(after char: Character?) -> TimeInterval {
        var delay = sampleLogNormal()

        if let char {
            if char.isWhitespace || char.isPunctuation { delay *= 1.35 }
            if let prev = previousChar, prev.isLetter || prev.isNumber,
               char.isLetter || char.isNumber { delay *= 0.85 }
        }

        // Clamp to [25%, 350%] of base
        delay = min(max(delay, baseDelay * 0.25), baseDelay * 3.5)

        // Thinking pause every 12 words
        if let char, !(char.isLetter || char.isNumber), wordChars > 0 {
            wordChars = 0
            wordsSincePause += 1
            if wordsSincePause >= 12 {
                wordsSincePause = 0
                delay += 0.3 + randomSource() * 0.2  // 300–500 ms thinking pause
            }
        } else if let char, char.isLetter || char.isNumber {
            wordChars += 1
        }

        previousChar = char
        return delay
    }

    private func sampleLogNormal() -> TimeInterval {
        let sigma = 0.35
        let mu = log(baseDelay) - 0.5 * sigma * sigma
        // Box-Muller transform
        let u1 = max(randomSource(), Double.leastNonzeroMagnitude)
        let u2 = randomSource()
        let gaussian = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
        return max(exp(mu + sigma * gaussian), baseDelay * 0.2)
    }
}

// MARK: - Mouse Profile

public enum MouseProfile: Sendable {
    /// Straight line, instant
    case linear
    /// Wind-gravity integration with optional overshoot
    case human(overshootProbability: Double = 0.2, seed: UInt64? = nil)
}

// MARK: - Main Driver

public final class HumanInputDriver: HumanInputDriving {
    private let source: CGEventSource?
    /// When non-nil, events are routed to this PID (background mode)
    public let targetPID: pid_t?

    public init(targetPID: pid_t? = nil) {
        self.source = CGEventSource(stateID: .hidSystemState)
        self.targetPID = targetPID
    }

    // MARK: - Type

    /// Type text character by character with the given cadence.
    /// Uses Unicode string path for non-ASCII characters — never hardcodes keycodes.
    public func type(_ text: String, cadence: TypingCadence = .humanWPM(150)) async throws {
        guard CGPreflightPostEventAccess() else { throw HumanInputError.permissionDenied }

        switch cadence {
        case let .fixed(ms):
            for char in text {
                try typeUnicode(String(char))
                if ms > 0 { try await Task.sleep(nanoseconds: UInt64(ms * 1_000_000)) }
            }
        case let .humanWPM(wpm):
            var ctx = HumanTypingCadence(wpm: wpm)
            for char in text {
                try typeUnicode(String(char))
                let delay = ctx.nextDelay(after: char)
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    // MARK: - Press (with modifier defer safety)

    /// Synthesize a key with optional modifiers.
    /// Uses `defer` to guarantee keyUp fires even if Task is cancelled.
    public func press(keyCode: CGKeyCode, modifiers: CGEventFlags = []) async throws {
        guard CGPreflightPostEventAccess() else { throw HumanInputError.permissionDenied }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { throw HumanInputError.eventCreationFailed }

        down.flags = modifiers
        up.flags   = modifiers

        var upPosted = false
        defer {
            if !upPosted { postEvent(up) }  // guarantees keyUp even on cancellation
        }
        postEvent(down)
        try await Task.sleep(nanoseconds: 1_000_000)  // 1 ms — Electron IPC survives this
        postEvent(up)
        upPosted = true
    }

    // MARK: - Move

    /// Move the cursor. Human profile uses wind-gravity integration.
    public func move(to point: CGPoint, profile: MouseProfile = .human()) async throws {
        guard CGPreflightPostEventAccess() else { throw HumanInputError.permissionDenied }
        // Read current cursor location; CGEvent created from .hidSystemState reports it via `.location`.
        let start = CGEvent(source: source)?.location ?? CGPoint.zero
        let path  = buildPath(from: start, to: point, profile: profile)

        guard let baseEvent = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: start,
            mouseButton: .left)
        else { throw HumanInputError.eventCreationFailed }

        let totalPoints = path.count
        guard totalPoints > 0 else { return }
        let stepNs = UInt64(500_000)  // ~0.5 ms per step; adjust for smoothness

        for pt in path {
            baseEvent.location = pt
            postEvent(baseEvent)
            try await Task.sleep(nanoseconds: stepNs)
        }
    }

    // MARK: - Click

    /// Click at a point (left button, configurable count).
    public func click(at point: CGPoint, count: Int = 1) async throws {
        guard CGPreflightPostEventAccess() else { throw HumanInputError.permissionDenied }
        let clampedCount = max(1, min(3, count))

        for i in 1...clampedCount {
            guard let down = CGEvent(
                mouseEventSource: source, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(
                    mouseEventSource: source, mouseType: .leftMouseUp,
                    mouseCursorPosition: point, mouseButton: .left)
            else { throw HumanInputError.eventCreationFailed }

            down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(i))

            if let pid = targetPID {
                down.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
                up.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
            }

            postEvent(down)
            try await Task.sleep(nanoseconds: 30_000_000)  // 30 ms down-to-up
            postEvent(up)

            if i < clampedCount {
                try await Task.sleep(nanoseconds: 80_000_000)  // 80 ms between clicks
            }
        }
    }

    // MARK: - Private Helpers

    /// Post a CGEvent either to a specific PID (background) or via HID tap (foreground).
    private func postEvent(_ event: CGEvent) {
        if let pid = targetPID {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    /// Type a single character or string using the Unicode string path.
    /// This avoids hardcoded keycodes and works across all keyboard layouts.
    private func typeUnicode(_ string: String) throws {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { throw HumanInputError.eventCreationFailed }

        let scalars = Array(string.unicodeScalars.map { $0.value })
        keyDown.keyboardSetUnicodeString(stringLength: scalars.count, unicodeString: scalars)
        keyUp.keyboardSetUnicodeString(stringLength: scalars.count, unicodeString: scalars)

        postEvent(keyDown)
        // 1 ms gap: prevents Electron/rich-text editors from dropping chars
        Thread.sleep(forTimeInterval: 0.001)
        postEvent(keyUp)
    }

    /// Minimal wind-gravity path builder (see GestureService+Paths.swift for full version).
    private func buildPath(from start: CGPoint, to end: CGPoint, profile: MouseProfile) -> [CGPoint] {
        switch profile {
        case .linear:
            let steps = 20
            return (1...steps).map { i in
                let t = Double(i) / Double(steps)
                return CGPoint(x: start.x + (end.x - start.x) * t,
                               y: start.y + (end.y - start.y) * t)
            }
        case let .human(overshootProb, seed):
            let dist   = hypot(end.x - start.x, end.y - start.y)
            var state  = seed ?? UInt64(Date().timeIntervalSinceReferenceDate * 1_000_000)
            func rng() -> Double {
                state = state &+ 0x9E3779B97F4A7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
                z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
                let r = z ^ (z >> 31)
                return Double(r) / Double(UInt64.max)
            }

            var cur = start
            var vx = 0.0, vy = 0.0
            var wx = 0.0, wy = 0.0
            var pts: [CGPoint] = []

            // Optional overshoot target
            var target = end
            if dist > 120, rng() < overshootProb {
                let extra = dist * (0.05 + rng() * 0.1)
                let dx = end.x - start.x, dy = end.y - start.y
                let len = max(0.001, hypot(dx, dy))
                target = CGPoint(x: end.x + dx / len * extra, y: end.y + dy / len * extra)
            }

            let steps = max(20, Int(220.0 + log2(dist + 1) * 90 + dist * 0.45) / 8)
            var settled = false
            for _ in 0..<steps {
                let ddx = target.x - cur.x, ddy = target.y - cur.y
                let dtd = max(0.001, hypot(ddx, ddy))
                let grav = log(min(max(dtd, 1), 800) + 2) * 1.8
                let gx = ddx / dtd * grav, gy = ddy / dtd * grav
                let wm = 0.6 * min(max(dtd / 400, 0.1), 1.0)
                wx = wx * 0.8 + (rng() * 2 - 1) * wm
                wy = wy * 0.8 + (rng() * 2 - 1) * wm
                vx = (vx + wx + gx) * 0.88
                vy = (vy + wy + gy) * 0.88
                cur.x += vx; cur.y += vy
                // Micro-jitter
                cur.x += (rng() * 2 - 1) * 0.35; cur.y += (rng() * 2 - 1) * 0.35
                pts.append(cur)
                if dtd <= 6 {
                    if target == end { settled = true; break }
                    target = end
                }
            }
            if !settled { pts.append(end) }
            return pts
        }
    }
}
```

### 使用示例

```swift
// 前台 app:直接合成
let driver = HumanInputDriver()
try await driver.type("Hello, World!", cadence: .humanWPM(150))
try await driver.press(keyCode: 0x24, modifiers: [])   // Return

// 后台 app:通过 PID 路由(鼠标事件需额外 stamp windowID,见 BackgroundInputDriver)
let bgDriver = HumanInputDriver(targetPID: targetApp.processIdentifier)
try await bgDriver.click(at: CGPoint(x: 400, y: 300))
try await bgDriver.type("background input", cadence: .fixed(milliseconds: 50))
```

## 新项目落地步骤(How to apply)

1. **确认权限**:在应用启动时调用 `CGPreflightPostEventAccess()`。若返回 `false`,抛出明确错误(`HumanInputError.permissionDenied`)并引导用户到系统偏好。不要静默失败——无权限时 `CGEvent.post` 会成功返回但事件被系统丢弃,极难排查。

2. **定义 `HumanInputDriving` 协议**:把真实驱动与 mock 分开。测试路径注入记录调用的 `MockHumanInputDriver`,生产路径注入 `HumanInputDriver`。这样 UI 测试不会污染真实 HID。

3. **选择节律**:引入 `TypingCadence` 枚举(`.fixed(ms)` / `.humanWPM(wpm)`)。对 agent/自动化场景默认 150 WPM;对 CI/regression 测试用 `.fixed(0)`(无间隔)或注入固定随机源确保确定性。

4. **处理 Unicode 字符**:对所有可打印字符统一走 `CGEventKeyboardSetUnicodeString` 路径——不要用 `CGKeyCode` 映射表处理普通文字。仅对箭头键、F1-F12、Delete、Return 等功能键保留 keycode 映射表(参考 `TypeServiceSpecialKeyMapping`)。

5. **保证 modifier 清理**:每次组合键序列都用 `defer` + 布尔标志确保 keyUp 一定发送。参考 `HotkeyService.performSyntheticHotkey:141-146` 的实现。

6. **后台投递**:若目标 app 不在前台,用 `BackgroundInputDriver` 模式:验证 pid 存活(`kill(pid, 0)`)→ 填充路由字段(`eventTargetUnixProcessID`、`windowID`) → `SLEventPostToPid` 优先,`postToPid` 回退。

7. **为 Electron 类目标写专用适配层**:检测目标 app 的 bundle ID 是否属于已知 Electron 框架(或包含 Electron.framework)。若是:先尝试 AX `setValue`,失败后 click-focus + `.cghidEventTap` + ≥1 ms 间隔;不用 `postToPid` 主进程。

8. **嵌入调试 hook**:在 `postEvent` 调用前后各加一行 `os.log` debug 级别日志,包含 event type、target pid、tap point。投入生产前可通过 `log stream --predicate` 实时观察事件流(详见调试节)。

9. **鼠标路径**:区分 `.linear`(性能敏感、截图、测试)和 `.human`(demo、需要可观测轨迹的场景)。`HumanMouseProfileConfiguration` 中注入 `randomSeed` 使演示可复现。

10. **测试分级**:不带 `PEEKABOO_INCLUDE_AUTOMATION_TESTS=true` 时只跑无副作用的单元测试(cadence 采样、路径生成);带 env 时才跑真实 HID 注入(需要 Accessibility 权限),对应 `pnpm run test:safe` vs `pnpm run test:automation`。参见 [12 · 测试策略](./12-testing-permission-gated.md)。

## 替代方案对比(When NOT to use)

| 方案 | 优点 | 缺点 | 何时选 |
|------|------|------|--------|
| **CGEvent 合成(本方案)** | 系统级、无需目标 app 配合、键鼠完整 | 拟真不完美、Electron 易出问题、需要 Accessibility 权限、沙盒受限 | 通用自动化 agent、需要键鼠组合的 UI 测试 |
| **AX `setValue`(直接写文本)** | 100% 可靠写入文本、绕过事件层、不受 Electron IPC 影响、无需拟真间隔 | 仅文本字段(`AXTextField`/`AXTextArea`)、非所有 app 实现 `AXSetValue`、无法触发键入相关副作用(如自动补全) | 文本输入为主、目标是原生 Cocoa 或 Electron 的 input 字段 |
| **AppleScript / `osascript`** | 高级语义(`tell application "Safari" to do JavaScript "..."`)、无需坐标 | 慢(进程间 AppleEvents)、仅部分 app 支持、需要 AppleEvents 权限、不适合高频调用 | 一次性脚本任务、需要应用级语义操作(打开 URL、操作菜单) |
| **`xdotool` / `cliclick` 等第三方工具** | 快速原型、无需代码 | 不在 macOS 原生栈、维护状态不明、沙盒/权限不受控 | 一次性验证、非产品化场景 |
| **私有 `SLEventPostToPid`(BackgroundInputDriver 的第一选择)** | 后台投递可靠性最高、不需要 app 在前台 | 私有 API、Mac App Store 审核会拒绝、Apple 随时可能移除 | 自用工具或企业内部分发,不过 MAS |
| **Chrome DevTools Protocol / Electron remote debugging** | 直接操作 DOM、可靠性高、绕开 UI 层 | 需要目标 app 以调试模式启动(生产版通常不开)、侵入性强 | 专门针对自有 Electron app 的自动化测试 |

**本方案失败时的决策树**:

1. 字段是文本框 → 先换 AX `setValue`
2. 目标是 Electron/Chrome → 见非原生环境节三级降级
3. 需要语义操作(菜单、URL) → `osascript`
4. 极端情况完全无效 → 录屏 + 手工;然后回来排查权限

## 非原生环境(Non-Native Targets)

### 8.1 Electron / Chromium 系(VSCode、Discord、Slack、Notion、Figma 桌面版)

**架构根因**:Electron 应用由一个主进程(Node.js)和若干渲染进程(Chromium)组成。键盘输入的最终接收者是渲染进程,但 macOS 给外部调用者暴露的 PID 通常是主进程。Chromium 在 **session 层**(`CGSessionEventTapLocation`)安装了事件 filter——合成事件在这一层被过滤掉,永远到达不了渲染进程。

**症状**:
- `CGEvent.post(tap: .cgSessionEventTap)` 投出去后 VSCode 编辑器无任何变化
- `event.postToPid(主进程 pid)` 同样无效
- 用 `.cghidEventTap` 且目标 app 在前台时偶尔有效,但稳定性差

**AX 树特征**:Chrome/Electron 的 AX 树有限——内容区域通常是 `AXWebArea` 下的 `AXGroup`,不暴露 `AXTextField`。VSCode 的编辑器区域在辅助功能检查器里是一个 `AXTextArea`(取决于版本),有时可写。Peekaboo 的 `ElementDetectionWindowResolver.swift:102` 加了 AX 超时保护专门应对 Chrome 多进程时返回空窗口列表的问题。

**处置策略(优先级降序)**:

1. **AX `setValue`**:用 Accessibility Inspector 确认目标 input element 是否存在且可写。VSCode(1.87+)和 Slack 的搜索框/消息输入框通常是可写的 `AXTextArea`。示例:
   ```swift
   // 找到 AXTextArea 后直接写入,绕过 event 层
   let result = actionInputDriver.trySetText(element: textAreaElement, text: text, replace: true)
   ```

2. **AX click-focus + `.cghidEventTap` + ≥1 ms 间隔**:先通过 AX 操作给 input element 发 `AXPress`(相当于点击激活),使渲染进程获得真正的 OS 焦点;再用 `.cghidEventTap` 发键盘事件。间隔必须 ≥1 ms,否则 Electron 的 IPC 消息队列来不及处理。
   ```swift
   // Step 1: AX focus
   AXUIElementPerformAction(inputElement, kAXPressAction as CFString)
   Thread.sleep(forTimeInterval: 0.05)  // 等 Electron IPC 完成聚焦
   // Step 2: cghidEventTap + Unicode path
   for char in text {
       try typeUnicode(String(char))
       Thread.sleep(forTimeInterval: 0.002)  // ≥1 ms 间隔
   }
   ```

3. **坐标点击聚焦 + `.cghidEventTap`**:若 AX 树完全不可用,先在目标坐标模拟左键点击使 app 获得焦点,再发键盘事件。这是最脆弱的方法,依赖坐标稳定。

**绝不可做**:
- `postToPid(主进程 pid)` 发键盘事件——到不了渲染进程
- `.cgSessionEventTap` 给 Electron——被 Chromium filter 拦截
- 零间隔连续 keyDown/keyUp——Electron IPC 队列丢事件
- 硬编码 CGKeyCode 处理字母/数字——布局无关性丢失

**Peekaboo 实证**:
- `ElementDetectionWindowResolver.swift:102`:Chrome 多进程问题:加 AX messaging timeout 以防空窗口列表
- `ElementClassifier.swift:50`:Chromium/Tauri 容器角色(`AXGroup`/`AXImage` 等)可能隐藏 clickable 内容,需要额外 `AXPress` 探测
- `ElementDetectionService.swift:215`:第一次遍历稀疏时触发 web focus fallback(`AXWebArea` 查找)

**可观测信号**:
```bash
# 检查目标 app 的 AX 树:打开 Accessibility Inspector,选择目标 app
open /Applications/Xcode.app/Contents/Applications/Accessibility\ Inspector.app

# 实时跟踪 AX 事件
log stream --predicate 'subsystem == "com.apple.accessibility" && category == "focus"' --info

# 检查 Electron 渲染进程 PID(与主进程不同!)
ps aux | grep -i "electron\|vscode\|slack\|discord" | grep -v grep
# 查看进程树
pstree -p <主进程 pid>
```

### 8.2 Web 浏览器内输入(Chrome / Safari / Edge / Arc 的页面内文本框)

**架构根因**:浏览器只将 web content 部分暴露到 AX 树,input 字段的实际接收者是 DOM。AX 查询通常找到 `AXWebArea` 下的 `AXTextField`(Chrome 暴露较好)或 `AXGroup`(Safari 有时暴露不足)。

**症状**:
- `CGEvent.post(tap: .cghidEventTap)` 在 Chrome tab 焦点时通常**有效**——因为 Chrome 主窗口拥有 OS 焦点
- 失败场景:扩展弹出窗口、画中画、多 WebContent 进程的特殊页面
- 用 AX 查询找到的是 `AXGroup` 而非 `AXTextField`

**处置**:
1. 确认浏览器窗口在前台(`CGEvent.post(tap: .cghidEventTap)` 即可)
2. 若需要与页面内元素交互而 AX 无法定位:考虑 Chrome DevTools Protocol(MCP 工具)——它走另一条完全独立的路径
3. 对 `AXWebArea` 内的 `AXTextField`:先读 `AXFocused` 确认焦点,再用 AX `setValue`

**可观测信号**:
```bash
# Console.app 过滤 AppKit 无障碍相关日志
log stream --predicate 'subsystem == "com.apple.AppKit" && category == "Accessibility"' --info --level debug

# 检查浏览器 AX 树是否开启
defaults read com.google.Chrome AXEnabled
# Safari 通常自动暴露 AX;可在 Safari → 偏好 → 高级 → 辅助功能 确认
```

**注意**:`defaults read com.apple.HIToolbox AppleSelectedInputSources` 检查当前输入法——在浏览器中输入中文时 CGEvent 键盘合成会先进 IME 候选框,需要切换到 ASCII 输入源或走 AX `setValue`。

### 8.3 终端模拟器 / TUI(Terminal.app / iTerm2 / Alacritty / WezTerm)

**架构根因**:终端不是文本字段,是 PTY(伪终端)。键盘事件经过 terminal emulator 解释后转为 PTY 序列。modifier 处理与原生 Cocoa 控件完全不同:Option 键常被配置为 meta(发 ESC 前缀),Shift+方向键触发文本选择而非移动光标。

**症状**:
- `Cmd+Shift+5` 等组合可能被 emulator 截获做截图而非发往 shell
- `Option+Delete` 发往 iTerm2 可能因 option-as-meta 配置不同而行为各异
- `CGEvent.post` 在终端通常**有效**(终端拥有 OS 焦点时),但 escape sequence 需要正确编码

**处置**:
- 对终端内的文本输入:`.cghidEventTap` + 目标 app 在前台,通常可靠
- 对需要确定 shell 输出的场景:不要用 CGEvent——改用 PTY 直接写入(`posix_spawn` + pipes)或 SSH + `expect`
- 对 iTerm2 脚本:Apple Script API (`tell application "iTerm2" to write text "..."`)更稳定
- 注意 `option-as-meta` 配置:在 iTerm2 中若 Left Option 配置为 +Esc:发 `Option+B` 会先发 `ESC` 再发 `b`;CGEvent modifier 路径不做此转换

**可观测信号**:
```bash
# 验证 PTY 接收到了按键序列
# 在目标终端运行 cat 并观察原始字节:
cat | od -c  # 然后通过 CGEvent 发送按键

# 检查 iTerm2 的 option key 配置
defaults read com.googlecode.iterm2 OptionKeySends
# 0 = normal, 1 = meta (+ESC), 2 = +0x20
```

### 8.4 Java Swing / JavaFX 应用

**特征**:Java 应用通过 JVM 的 AWT 事件泵处理 CGEvent;AX 树由 Java Accessibility Bridge 生成,质量参差不齐。

**已知问题**:`CGKeyCode` 组合在 Swing 内有时被重新解释(JVM 维护自己的 key map);AX `setValue` 通常可用于 `JTextField`。

**处置**:优先 AX `setValue`;若需要快捷键操作,用 `CGEvent.post(tap: .cghidEventTap)` + ≥5 ms 间隔(JVM 事件泵比原生慢)。

## 调试与取证(Debug & Forensics)

### 症状 → 排查命令 → 根因映射

| 症状 | 第一步排查命令 | 可能根因 |
|------|--------------|---------|
| 字段完全没变化 | `log stream --predicate 'subsystem == "boo.peekaboo.core" && category == "TypeService"' --level debug` 看事件是否发出 | 权限缺失 / event 未创建 / tap 选错(session vs hid) |
| 字符顺序乱或漏字符 | 把间隔临时加到 10 ms 看是否复现:`TypingCadence.fixed(milliseconds: 10)`;观察 `TypeService+SpecialKeys.swift:87` 的 1 ms 是否够 | 零间隔触发 Electron IPC 丢事件;富文本 runloop 来不及处理 |
| 大写/快捷键意外触发 | `log show --predicate 'eventMessage CONTAINS "modifier" || eventMessage CONTAINS "flags"' --last 5m` | modifier flag 残留;keyUp 未发送 |
| Dvorak/Colemak 布局下输出错误字符 | `defaults read com.apple.HIToolbox AppleSelectedInputSources \| grep -i "input"` 查当前布局 | 使用了硬编码 CGKeyCode 而非 Unicode 字符路径 |
| 输入法候选框弹出 | `TISCopyCurrentKeyboardInputSource()` 检查当前输入源 | IME 激活时 keystroke 进候选框;改用 AX `setValue` 或先切换 ASCII 输入源 |
| Electron/VSCode 中完全无效 | 打开 Accessibility Inspector 查目标元素是否有 `AXValue`;`ps aux \| grep Electron` 查渲染进程 PID | 应用多进程;渲染进程 PID 与主进程不同;Chromium session filter |
| 后台投递无效 | `ps -p <pid>` 验 pid 存活;检查 `BackgroundInputDriver.windowID` 是否返回 nil(窗口不在屏幕上?) | 路由字段未填充;窗口被最小化或隐藏;私有 API 不可用 |
| 事件发出但目标 app 无响应 | `sudo dtrace -n 'syscall::write:entry /execname == "Electron Helper"/ { printf("%s\n", copyinstr(arg1)); }' -c <command>` (需 SIP 部分关闭)或改用 lldb attach | 事件到达进程 event queue 但 responder chain 无处理者 |

### 关键工具详解

**1. Accessibility Inspector**

路径:`/Applications/Xcode.app/Contents/Applications/Accessibility Inspector.app`

用途:查看目标 app 的完整 AX 树。重点检查:
- 目标 input element 的 role(是 `AXTextField` 还是 `AXGroup`?)
- `AXValue` 属性是否存在且可写(显示为 `settable: YES`)
- `AXFocused` 是否为 `YES`

操作:点击 Inspector 工具栏的 target 图标 → 点击目标 app 的 input 区域 → 右侧 Attributes 面板查看属性。

**2. `log stream` 实时跟踪**

```bash
# 跟踪 Peekaboo automation 输入日志
log stream \
  --predicate 'subsystem == "boo.peekaboo.core" && (category == "TypeService" || category == "HotkeyService")' \
  --level debug

# 跟踪 AppKit 无障碍和键盘事件
log stream \
  --predicate 'subsystem == "com.apple.AppKit" && (category == "Accessibility" || category == "keyboard")' \
  --level info

# 跟踪 CGEvent post 操作(macOS 系统层)
log stream \
  --predicate 'subsystem == "com.apple.hiservices-xpcservice"' \
  --level debug

# 查看最近 5 分钟的 modifier 相关日志(回溯排查残留问题)
log show \
  --predicate 'eventMessage CONTAINS "modifier" || eventMessage CONTAINS "CGEventFlags"' \
  --last 5m
```

**3. Accessibility Inspector 命令行等效**

```bash
# 检查应用是否有 AX 权限(当前进程视角)
python3 -c "import Cocoa; print(Cocoa.AXIsProcessTrusted())"

# 检查系统权限状态
tccutil reset Accessibility com.yourapp.bundleid   # 重置权限(测试用)

# 列出授权的辅助功能客户端
sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, allowed FROM access WHERE service='kTCCServiceAccessibility';"
```

**4. 验证 Electron 渲染进程 PID**

```bash
# 找到 VSCode 所有进程(主进程 + 渲染进程)
pgrep -l "Electron\|Code Helper\|VSCode"

# 查看进程树
pstree -p $(pgrep "Code - OSS" | head -1)

# 验证某个 PID 是渲染进程还是主进程
ps -p <pid> -o command=
# 渲染进程通常包含 --type=renderer
```

**5. 测试 CGEvent 权限和投递**

```bash
# 快速权限检测(Swift one-liner)
swift -e 'import CoreGraphics; print(CGPreflightPostEventAccess())'

# 用 cliclick 验证坐标系(排除 Peekaboo 代码问题,直接测系统层)
brew install cliclick
cliclick t:"Hello" c:400,300   # 在坐标 400,300 点击后输入 Hello
```

**6. 录制复现视频**

```bash
# 真机录屏(QuickTime 用于手动操作记录)
screencapture -v /tmp/repro.mov

# 获取屏幕当前状态截图(用于坐标验证)
screencapture -x /tmp/screenshot.png
```

## 常见陷阱(Pitfalls)

### 陷阱 1 · 零间隔被视为机器输入导致漏字符

**症状**:输入后字段内容比预期短,字符数对不上,且错误是非确定性的(有时成功有时失败)。

**可观测信号**:在 Electron/Slack/VSCode 中用 `TypingCadence.fixed(milliseconds: 0)` 输入 20 字符,实际只出现 12-18 字符,且每次运行丢失的字符不同。

**检查命令**:
```bash
# 临时将间隔加大到 10 ms 再试:如果字符不再丢失,就是间隔问题
# 在 Peekaboo 中
peekaboo type --text "test string" --delay 10
```

**处理**:在每对 keyDown/keyUp 之间插入至少 1 ms。`TypeServiceSpecialKeyMapping.postKey` 已在第 87 行内置 `Thread.sleep(forTimeInterval: 0.001)`;普通字符的 `performSyntheticType` 路径通过 `TypingCadence` 控制。

**来源**:`TypeService+SpecialKeys.swift:87` 的注释和实现;Peekaboo 在早期迭代中遇到过 Slack 消息框丢字符问题后加入该间隔。

---

### 陷阱 2 · Modifier flag 未清理影响后续输入

**症状**:合成带修饰键的事件后,随后的普通输入变成大写,或意外触发快捷键(例如之后的 "s" 触发了 Cmd+S)。

**可观测信号**:在一次 `Cmd+Shift+A` 操作后,下一行文本输入全部大写;Console.app 中 AppKit keyboard 日志显示 shift flag 持续为 `true`。

**检查命令**:
```bash
log show \
  --predicate 'eventMessage CONTAINS "modifier" && subsystem == "com.apple.AppKit"' \
  --last 2m
```

**处理**:组合键序列末尾用 `defer` + 布尔标志确保 keyUp 发送,keyUp 时 `flags` 与 keyDown 相同(而非清零):`HotkeyService.performSyntheticHotkey:138-146`。

**来源**:`HotkeyService.swift:141-146` 的 `defer` 实现;修饰键残留是经典 CGEvent 使用错误,参见 Apple 技术文档 [Quartz Event Services: CGEventFlags]。

---

### 陷阱 3 · 硬编码 CGKeyCode 在非 QWERTY 布局错位

**症状**:在 Dvorak、Colemak 或用中文/日文输入法的系统上,`peekaboo type "hello"` 输出错误字符(如 "aoeui" 而非 "hello")。

**可观测信号**:切换到 Dvorak 布局后输出明显错位,切回 QWERTY 后恢复。

**检查命令**:
```bash
# 查看当前输入源
defaults read com.apple.HIToolbox AppleSelectedInputSources | grep -A3 "InputSourceKind"

# 或者通过 TIS API
swift -e '
import Carbon
let src = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()
let name = TISGetInputSourceProperty(src, kTISPropertyLocalizedName) as! String
print(name)'
```

**处理**:对普通文字使用 `CGEventKeyboardSetUnicodeString`(Unicode 路径),仅对功能键保留 keycode 映射表(`TypeServiceSpecialKeyMapping`)。Unicode 路径与键盘布局完全无关。

**来源**:`docs/human-typing.md` 中"Realistic jitter curves"节提到了输入方式与布局解耦的设计目标;`TypeServiceSpecialKeyMapping` 的分离也体现了这一原则。

---

### 陷阱 4 · 输入法(IME)拦截 keystroke

**症状**:字段无文字,但 IME 候选框弹出;或输入的是拼音/假名而非预期文字。

**可观测信号**:在中文系统上自动化输入 "zhongwen" 时,候选框弹出显示"中文"候选词,但目标字段为空。

**检查命令**:
```bash
# 检查当前输入法是否为 ASCII-capable
swift -e '
import Carbon
let src = TISCopyCurrentKeyboardInputSource()!.takeRetainedValue()
let isASCII = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsASCIICapable) as! Bool
print("Is ASCII capable:", isASCII)'
```

**处理**:
1. 优先走 AX `setValue`——完全绕过 IME
2. 若必须合成:调用 `TISCopyCurrentKeyboardInputSource` 检测输入法 → 若非 ASCII-capable,临时切换 ASCII 源(`TISSelectInputSource(asciiSource)`) → 合成完成后恢复原输入法
3. 或直接用 Unicode 字符路径(`CGEventKeyboardSetUnicodeString`)——对已组合的 Unicode 字符(如 "中"),此方法可直接绕过 IME

**来源**:Peekaboo `TypeService` 的 AX 优先设计就是为了规避此问题(`TypeService.swift:114-129`)。

---

### 陷阱 5 · Electron 后台进程 `postToPid` 无效

**症状**:用 `BackgroundInputDriver` 向 VSCode/Slack 发送键盘事件,完全无反应;但同样的代码对原生 macOS app 有效。

**可观测信号**:在 `BackgroundInputDriver.post(_:to:)` 中加日志确认事件已发出;使用 Accessibility Inspector 查目标 app 的 AX 树,发现 input element 不在主进程的 AX 树下,而在渲染进程的子树。

**检查命令**:
```bash
# 确认目标进程的父子关系
pstree -p $(pgrep "Electron" | head -1)
# 找到渲染进程 PID 后验证
ps -p <renderer_pid> -o pid,ppid,command=

# 验证事件路由:在 Peekaboo 日志里搜索 postToPid 调用
log stream \
  --predicate 'subsystem == "boo.peekaboo.core" && category == "BackgroundInputDriver"' \
  --level debug
```

**处理**:对 Electron,放弃 `postToPid` 键盘路径;改用 AX `setValue`(如 input field 可写)或 `.cghidEventTap`(需要 app 在前台)。若必须后台键盘输入,考虑 Chrome DevTools Protocol。

**来源**:`ElementDetectionWindowResolver.swift:102` 注释提到 Chrome 多进程导致的 AX 窗口列表问题,同样的多进程架构也影响事件路由。

## 延伸阅读

- Peekaboo 内部文档:`docs/human-typing.md`、`docs/human-mouse-move.md`、`docs/automation.md`
- Apple 官方:
  - [Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz_event_services)
  - [CGEvent Reference](https://developer.apple.com/documentation/coregraphics/cgevent)
  - [Text Input Programming Guide – Input Method Kit](https://developer.apple.com/library/archive/documentation/TextFonts/Conceptual/CocoaTextArchitecture/TextEditing/TextEditing.html)
  - [Accessibility Programming Guide for macOS](https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/index.html)
- 工具:
  - Accessibility Inspector:`/Applications/Xcode.app/Contents/Applications/Accessibility Inspector.app`
  - `log stream --predicate` 语法:[Unified Logging](https://developer.apple.com/documentation/os/logging)
- 其它 playbook:
  - [05 · 权限状态机](./05-permissions-state-machine.md) — `CGPreflightPostEventAccess()` 与 Accessibility 权限流程
  - [06 · AXorcist 元素查找](./06-ax-automation-axorcist.md) — AX `setValue` 的 element 定位前置步骤
  - [10 · Visualizer overlay](./10-visualizer-overlay.md) — 输入时的视觉反馈叠加
  - [12 · 测试策略](./12-testing-permission-gated.md) — CGEvent 测试的 env gating 与 safe/automation 分级

---
*Last verified against Peekaboo @ `db2b2a772705688b1e0c7bab2a491527b6720805`*
