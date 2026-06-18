---
summary: 'CGEvent 拟真输入合成:对数正态击键间隔、风/重力鼠标轨迹、Modifier defer 安全、Electron/Chrome 三级降级策略。'
read_when:
  - '实现需要看起来自然的自动化键盘/鼠标输入'
  - '向 Electron、Chrome、VSCode 等非原生目标可靠地投递合成事件'
  - '调试漏字符、modifier 残留、后台进程输入无效等问题'
sources: ['P07']
last_verified:
  peekaboo: 'db2b2a772705688b1e0c7bab2a491527b6720805'
  nemonotch: 'fe4e9e5'
---

# CGEvent 拟真输入合成

## TL;DR

macOS `CGEvent` API 可在软件层合成键盘与鼠标事件,但"发出去"不等于"被目标感知"。Peekaboo 在原始合成之上叠加两层拟真:打字节律用**对数正态分布**模拟击键间隔(150 WPM → ~80 ms 基础延迟,±35% 对数正态抖动),鼠标路径用**风/重力积分 + 可控超调**模拟手部轨迹。整个输入链优先走 **AX `setValue`**——仅当 AX 路径不可用时降级到 CGEvent——这使大多数原生 Cocoa 控件既快速又可靠。对于 Electron / Chromium 系(VSCode、Discord、Slack 等)**非原生**目标,主进程↔渲染进程 IPC 以及 Chromium 在 session 层安装的事件 filter 会让 `.cgSessionEventTap` 失效;Peekaboo 通过 AX `setValue` 优先、click-focus 聚焦、`.cghidEventTap` + ≥1 ms 间隔三级降级应对。

## 可复用模式

### 1 · 投递目标选择:`CGEvent.post` vs `postToPid` vs `SLEventPostToPid`

| 场景 | 推荐方式 | 注意 |
|------|---------|------|
| 目标 app 已在前台 | `event.post(tap: .cghidEventTap)` | 最兼容,走标准 HID 栈 |
| 目标 app 在后台 | `event.postToPid(pid)` | 需先 stamp `eventTargetUnixProcessID`、`windowID` 等路由字段 |
| 后台且需最高可靠性 | `SLEventPostToPid`(SkyLight 私有)→ 失败时回退 `postToPid` | 私有 API,Mac App Store 不可用 |
| Electron/Chrome 渲染进程 | AX `setValue` 优先;AX 不可用时用 `.cghidEventTap` + 先 click-focus | 不要用 `postToPid` 主进程 |

双路 post 封装(`BackgroundInputDriver.swift:61-65`):

```swift
private static func post(_ event: CGEvent, to pid: pid_t) {
    if !SkyLightPerPidEventPost.post(event, to: pid) {
        event.postToPid(pid)
    }
}
```

路由字段必须在 `post` 前 stamp(`BackgroundInputDriver.swift:67-82`):

```swift
private static func stampRoutingFields(
    on event: CGEvent, at point: CGPoint, targetProcessIdentifier: pid_t)
{
    event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(targetProcessIdentifier))
    guard let windowID = self.windowID(containing: point, targetProcessIdentifier: targetProcessIdentifier) else { return }
    let value = Int64(windowID)
    event.setIntegerValueField(.windowID, value: value)
    event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: value)
    event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: value)
}
```

### 2 · 打字节律:对数正态采样

`HumanTypingContext` 在 `TypeService+TypingCadence.swift:55-149` 实现完整拟真节律。核心采样函数(`TypeService+TypingCadence.swift:125-131`):

```swift
private mutating func sampleLogNormal() -> TimeInterval {
    let sigma = Constants.logNormalSigma  // 0.35
    let mu = log(self.baseDelay) - 0.5 * sigma * sigma
    let gaussian = Self.generateGaussian(using: self.random)  // Box-Muller
    let value = exp(mu + sigma * gaussian)
    return max(value, self.baseDelay * 0.2)   // 下限 0.2×
}
```

关键参数(全部来自 `Constants`):

| 参数 | 值 | 说明 |
|------|----|------|
| `logNormalSigma` | 0.35 | 形状参数;控制抖动幅度 |
| `baseDelay` | `60.0 / (wpm * 5)` | 150 WPM → ~80 ms |
| `punctuationMultiplier` | 1.35 | 标点/空白字符乘数 |
| `digraphMultiplier` | 0.85 | 连续字母 digraph 乘数 |
| 下限钳制 | `baseDelay * 0.2` | 实测代码值 |
| 上限钳制 | `baseDelay * 3.5` | 实测代码值 |
| `thinkingWordInterval` | 12 | 每 12 个词插入 300–500 ms 思考停顿 |

随机源(`TypingCadenceRandomSource` 协议)可注入:生产路径用 `SystemTypingCadenceRandomSource`,测试注入固定序列确保确定性。

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
current = self.applyJitter(point: current, rng: &rng)  // ±jitterAmplitude px
```

关键参数:
- `overshootProbability`:距离 ≤ 120 px 不超调,超过才按概率触发
- `settleRadius`:进入后切换为真实目标坐标
- 持续时间估算:`220 + log2(dist+1)*90 + dist*0.45` ms,夹在 [250, 1600]
- `jitterAmplitude` 默认约 0.35 px,通过 `HumanMouseProfileConfiguration` 配置
- 随机源 `SeededGenerator`(Splitmix64 变体),种子可外部注入(`GestureService+Paths.swift:168-171`)

### 4 · Modifier flag 正确组合与 defer 重置

`HotkeyService.performSyntheticHotkey` 展示了正确的 modifier 生命周期(`HotkeyService.swift:138-146`):

```swift
keyDown.flags = plan.modifierFlags
keyUp.flags = plan.modifierFlags
keyDown.post(tap: .cghidEventTap)
var keyUpPosted = false
defer {
    if !keyUpPosted {
        keyUp.post(tap: .cghidEventTap)  // 确保 keyUp 一定执行,即使 Task.sleep 被取消
    }
}
// ... Task.sleep(holdNanoseconds) ...
keyUp.post(tap: .cghidEventTap)
keyUpPosted = true
```

常用 modifier bits:`maskShift = 0x20000`、`maskCommand = 0x100000`、`maskAlternate = 0x80000`、`maskControl = 0x40000`。

### 5 · AX 优先,CGEvent 降级

`TypeService` 通过 `UIInputDispatcher` 先尝试 AX action,失败后降级到 CGEvent 合成(`TypeService.swift:89-111`):

```swift
action: {
    // AX 路径: performActionType → trySetText(element:text:replace:)
    // 绕过事件层,不受 Electron IPC 影响
    try await self.performActionType(text: text, target: target, ...)
},
synth: {
    // CGEvent 降级路径: performSyntheticType
    // click-focus 后逐字符合成键盘事件
    try await self.performSyntheticType(text: text, target: target, ...)
}
```

### 6 · 非原生 app 三级降级

| 优先级 | 方式 | 适用场景 | 失败信号 |
|--------|------|---------|---------|
| 1 | AX `setValue`(via `trySetText`) | AX 树暴露 `AXTextField`/`AXTextArea` 且实现 `AXSetValue` | 返回 `ActionInputError.unsupported` |
| 2 | AX click 聚焦 + `.cghidEventTap` + ≥1 ms 间隔 + Unicode 路径 | Electron/Chrome 中 input field 能获得 AX focus 但 AXValue 不可写 | 字符丢失、顺序乱,或 IME 候选框弹出 |
| 3 | 坐标点击聚焦 + `.cghidEventTap` | AX 树完全不可用,只知道屏幕坐标 | 依赖坐标稳定性,最脆弱 |

**绝不可做**:在 Electron/Chrome 中用 `postToPid(主进程 pid)` 投递键盘事件——事件进入主进程 event queue 而非渲染进程,完全无效。

## 锚点

| 文件:行 | 功能 |
|---------|------|
| `SyntheticInputDriver.swift:6` | `SyntheticInputDriving` 协议定义 |
| `TypeService+TypingCadence.swift:55-149` | `HumanTypingContext`:完整打字节律 |
| `TypeService+TypingCadence.swift:125-131` | `sampleLogNormal()`:对数正态采样,下限 `0.2×` |
| `GestureService+Paths.swift:56` | `HumanMousePathGenerator`:风/重力积分路径 |
| `GestureService+Paths.swift:87-116` | 风/重力积分主循环 |
| `GestureService+Paths.swift:168-171` | 随机种子注入 |
| `BackgroundInputDriver.swift:11` | `BackgroundInputDriver`:后台 PID 路由 |
| `BackgroundInputDriver.swift:61-65` | `post(_:to:)`:双路 SkyLight→postToPid |
| `BackgroundInputDriver.swift:67-82` | `stampRoutingFields`:路由字段 stamp |
| `HotkeyService.swift:127-158` | `performSyntheticHotkey`:modifier defer 安全 |
| `HotkeyService.swift:138-146` | keyUp defer + keyUpPosted 标志 |
| `TypeService.swift:89-111` | `UIInputDispatcher` AX 优先/CGEvent 降级分支 |
| `TypeService.swift:114-130` | `performActionType`:AX `trySetText` 入口 |
| `TypeService+SpecialKeys.swift:79` | `postKey`:特殊键合成,1 ms 间隔内置 |
| `ElementDetectionWindowResolver.swift:102` | Chrome 多进程 AX 超时保护 |
| `ElementDetectionService.swift:215` | 稀疏遍历触发 web focus fallback |

## Pitfalls

**1. 零间隔被视为机器输入导致漏字符**
在 Electron/Slack/VSCode 中用 `TypingCadence.fixed(milliseconds: 0)` 输入 20 字符,实际只出现 12-18 字符,且每次丢失的字符不同。处理:在每对 keyDown/keyUp 之间插入至少 1 ms。`TypeServiceSpecialKeyMapping.postKey`(`TypeService+SpecialKeys.swift:87`)已内置 `Thread.sleep(forTimeInterval: 0.001)`。

**2. Modifier flag 未清理影响后续输入**
合成带修饰键事件后,随后的普通输入变成大写或意外触发快捷键。处理:`HotkeyService.performSyntheticHotkey:141-146` 用 `defer` + `keyUpPosted` 标志确保 keyUp 一定发送;keyUp 时 `flags` 与 keyDown 相同(非清零)。

**3. 硬编码 CGKeyCode 在非 QWERTY 布局错位**
在 Dvorak、Colemak 或中日文输入法系统上,`peekaboo type "hello"` 输出错误字符。处理:对所有可打印字符统一走 `CGEventKeyboardSetUnicodeString` Unicode 路径,仅对功能键(箭头、F1-F12、Delete、Return)保留 keycode 映射(`TypeServiceSpecialKeyMapping`)。

**4. 输入法(IME)拦截 keystroke**
中文系统上自动化输入 "zhongwen" 时,候选框弹出但目标字段为空。处理:①优先走 AX `setValue`(完全绕过 IME);②若必须合成:检测输入法 → 临时切换 ASCII 源 → 合成后恢复。

**5. Electron 后台进程 `postToPid` 无效**
向 VSCode/Slack 用 `BackgroundInputDriver` 发键盘事件完全无反应。根因:Chromium 在 session 层安装 event filter;渲染进程 PID 与主进程不同,`postToPid(主进程 pid)` 事件无法抵达渲染进程。处理:改用 AX `setValue` 或 `.cghidEventTap`(需 app 在前台)。

**6. 打字节律下限钳制值:历史上有两种写法**
实测 Peekaboo 源码(`TypeService+TypingCadence.swift:93`)中 `sampleLogNormal()` 的下限钳制为 `baseDelay * 0.2`。文档曾在参数描述部分写成 `0.25×`——**以 `0.2×` 为准**。若遇到 `0.25×` 的表述,优先检查 `TypeService+TypingCadence.swift:93` 的实际代码。

**7. `CGPreflightPostEventAccess()` 返回 false 时 post 静默失败**
无权限时 `CGEvent.post` 调用成功返回但事件被系统丢弃,极难排查。必须在启动时检测权限并明确引导用户授权。

## 落地 checklist

1. 确认权限:启动时调用 `CGPreflightPostEventAccess()`,返回 `false` 时抛出明确错误,不静默失败
2. 定义 `HumanInputDriving` 协议:分离真实驱动与 mock,测试注入记录调用的 mock 实现
3. 选择节律:agent/自动化场景默认 150 WPM;CI 测试用 `.fixed(0)` 或注入固定随机源
4. 所有可打印字符走 `CGEventKeyboardSetUnicodeString`;功能键走 keycode 映射表
5. 每次组合键序列用 `defer` + 布尔标志保证 keyUp 一定发送
6. 后台投递:验证 pid 存活 → 填充路由字段 → `SLEventPostToPid` 优先 → `postToPid` 回退
7. Electron 类目标:检测 bundle ID / 进程树 → AX `setValue` 优先 → click-focus + `.cghidEventTap` → 不用 `postToPid` 主进程
8. 在 `postEvent` 前后加 `os.log` debug 日志(event type、target pid、tap point),便于 `log stream --predicate` 实时观察

## 延伸阅读

- [全局 NSEvent 监听](global-event-monitor.md) — 捕获鼠标移动/点击
- [../permissions/](../permissions/) — `CGPreflightPostEventAccess()` 与 Accessibility 权限状态机
- [../accessibility/](../accessibility/) — AX `setValue` 的 element 定位前置步骤(AXorcist)
- Peekaboo 内部文档:`docs/human-typing.md`、`docs/human-mouse-move.md`
- Apple 官方:[Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz_event_services)、[CGEvent Reference](https://developer.apple.com/documentation/coregraphics/cgevent)
