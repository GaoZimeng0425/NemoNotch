---
summary: 'Synthesize realistic keyboard and mouse input via CGEvent with log-normal timing and wind-gravity mouse trajectories.'
read_when:
  - 'implementing automated input injection that needs to appear human-like'
  - 'making CGEvent-based input reliably perceived by target applications'
---

# 07 · CGEvent 拟真输入

## TL;DR

macOS 的 `CGEvent` API 可以在软件层合成键盘与鼠标事件,但"发出去"不等于"被目标感知"。Peekaboo 在原始合成之上叠加了两层拟真:打字节律用**对数正态分布**模拟击键间隔,鼠标路径用**风/重力积分 + 可控超调**模拟手部轨迹。这两层都有可注入的随机源,测试时可固定种子换取确定性。核心原则是:先用 AX 定位目标元素,再合成输入——坐标只是最终手段。

## Peekaboo 在哪里实现

- 模块:`PeekabooAutomationKit`
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/SyntheticInputDriver.swift:49` — 薄壳包装,将 `AXorcist.InputDriver` 的底层调用与上层服务解耦
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/TypeService+TypingCadence.swift:56` — `HumanTypingContext`:对数正态采样、标点乘数、词间思考停顿
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/GestureService+Paths.swift:56` — `HumanMousePathGenerator`:风/重力积分、超调、微抖动
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/BackgroundInputDriver.swift:11` — `BackgroundInputDriver`:向目标 pid 路由事件而不扰动前台
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/TypeService+SpecialKeys.swift:79` — `TypeServiceSpecialKeyMapping.postKey`:用 `post(tap: .cghidEventTap)` 合成特殊键
- 相关 docs:`docs/human-typing.md`、`docs/human-mouse-move.md`

## 设计动机(Why)

自动化测试和 AI agent 驱动 UI 时,目标应用有三种常见防御:

1. **速率检测** — 高频无间隔事件被识别为机器;部分富文本编辑器内部有事件队列,零间隔会丢字符。
2. **修饰键残留** — 若 shift/cmd 按下后未被显式抬起,后续输入会意外带修饰符,表现为选中、删除等副作用。
3. **后台投递失效** — `CGEvent.post(tap: .cghidEventTap)` 走全局 HID 管道,需要前台焦点;向后台进程投递必须改用 `event.postToPid(pid)` 或私有 `SLEventPostToPid`,并设置 `eventTargetUnixProcessID`、`windowID` 等路由字段。

## 核心模式(Pattern)

### 1 · `CGEvent.post(tap:)` vs `CGEvent.postToPid()`

| 场景 | 推荐方式 | 注意 |
|------|---------|------|
| 目标 app 已在前台 | `event.post(tap: .cghidEventTap)` | 最兼容,走标准 HID 栈 |
| 目标 app 在后台 | `event.postToPid(pid)` | 需设置路由字段;部分 app 仍会忽略 |
| 后台且需最高可靠性 | `SLEventPostToPid`(私有,沙盒/MAS 不可用,需评估发行渠道) + `postToPid` 回退 | 见 `BackgroundInputDriver.post(_:to:)` |

### 2 · 打字节律:对数正态采样

```swift
// TypeService+TypingCadence.swift:125-131
private mutating func sampleLogNormal() -> TimeInterval {
    let sigma = 0.35                          // 形状参数
    let mu = log(baseDelay) - 0.5 * sigma * sigma
    let gaussian = Self.generateGaussian(using: random) // Box-Muller
    return exp(mu + sigma * gaussian)
}
```

- `baseDelay = 60.0 / (wpm * 5)`:150 WPM → ~80 ms 基础间隔
- 标点/空白乘 `1.35`,连续字母(digraph)乘 `0.85`
- 每 12 个词插入 300–500 ms"思考停顿"
- 延迟值夹在 `[baseDelay*0.25, baseDelay*3.5]`

### 3 · 鼠标路径:风/重力积分

```swift
// GestureService+Paths.swift:87-103
velocity = (velocity + wind + gravity) * 0.88   // 阻尼
current += velocity
current = applyJitter(point: current, rng: &rng) // ±0.35 px
```

- `overshootProbability = 0.2`,距离 < 120 px 时不超调
- `settleRadius = 6 px`,进入后切换至真实目标
- 持续时间估算:`220 + log2(dist+1)*90 + dist*0.45` ms,夹在 [250, 1600]

### 4 · Modifier flag 正确组合

```swift
// 正确:合成时传入 flags,事件结束后不留残余
let event = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)!
event.flags = [.maskShift, .maskCommand]   // 位或组合
event.post(tap: .cghidEventTap)
// keyUp 时传相同 flags,确保配对抬起
```

常用位:`maskShift = 0x20000`、`maskCommand = 0x100000`、`maskAlternate = 0x80000`、`maskControl = 0x40000`。

### 5 · AX 优先,坐标兜底

```swift
// TypeService.swift:121-129  先找元素
if let element = try await resolveAutomationElement(target: target, snapshotId: snapshotId) {
    return try actionInputDriver.trySetText(element: element, text: text, replace: clearExisting)
}
// 元素找不到才退化到合成点击 + 逐字输入
```

## 新项目落地步骤(How to apply)

1. 确认 `CGPreflightPostEventAccess()` 返回 `true`——需要"辅助功能"或"输入监控"权限;缺失时抛出明确错误而非静默失败。
2. 抽象出 `SyntheticInputDriving` 协议并在生产路径注入真实驱动、在测试路径注入 mock,避免测试污染真实 HID。
3. 打字节律:引入 `TypingCadence` 枚举(`.fixed(ms)` / `.human(wpm)`),在循环中调用对数正态采样器,注入可替换的随机源以保证测试确定性。
4. 鼠标路径:在 `MouseMovementProfile` 中区分 `.linear` 与 `.human`,仅在需要拟真展示时启用风/重力积分,性能敏感场景保持线性插值。
5. 键盘布局适配:对非 ASCII 字符走 Unicode 字符路径(`UCKeyTranslate` 或直接设 `unicodeString`),不要硬编码 `CGKeyCode`;特殊键用字符串名称映射表统一管理。
6. 后台投递:若目标 app 不在前台,用 `postToPid` + 路由字段(`eventTargetUnixProcessID`、`windowID`),并在调用前验证 pid 存活。
7. 序列收尾:每次组合键序列结束后,显式发送所有 modifier 的 `keyUp` 事件,防止修饰符状态泄漏。

## 常见陷阱(Pitfalls)

- **零间隔被视为机器输入导致漏字符** — 目标 app(尤其富文本、输入验证组件)内部事件队列无法在同一 runloop 周期处理连续 keyDown/keyUp;可观测信号:输入后字段内容比预期短,字符数对不上。处理方式:在每对 keyDown/keyUp 之间插入至少 1 ms(`Thread.sleep` 或 `Task.sleep`);`TypeServiceSpecialKeyMapping.postKey` 已用 1 ms 间隔(`TypeService+SpecialKeys.swift:87`)。来源:Peekaboo 实现经验。

- **modifier flag 未清理影响后续输入** — 合成带修饰键的事件后若未发送对应的 keyUp(或 keyUp 时 flags 为空),系统 modifier 状态机残留 shift/cmd;可观测信号:后续普通输入字符变成大写或触发快捷键。处理方式:组合键序列末尾显式清零 flags 并发送所有 modifier 的 keyUp;`HotkeyService` 在 line 138-146 用 defer 保证 keyUp 发送。

- **硬编码 keycode 在非 QWERTY 布局错位** — `CGKeyCode` 是物理键位置,在 Dvorak、Colemak 或中文/日文系统下映射与 QWERTY 不同;可观测信号:在 Dvorak 用户机器上 `peekaboo type "hello"` 输出错误字符。处理方式:对普通文本使用 Unicode 路径(`CGEventKeyboardSetUnicodeString`),仅对特殊功能键保留 keycode 映射表。

- **输入法拦截 keystroke** — IME 激活时,按键进入候选框而非目标字段;可观测信号:字段无文字但 IME 候选窗弹出。处理方式:优先走 AX `setValue`;若必须合成,先用 `TISCopyCurrentKeyboardInputSource` 检测并临时切换 ASCII 源。

## 延伸阅读

- Peekaboo:`docs/human-typing.md`、`docs/human-mouse-move.md`
- Apple:[Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz_event_services)
- 其它 playbook:[05 · 权限](./05-permissions-state-machine.md)、[06 · AXorcist](./06-ax-automation-axorcist.md)、[10 · Visualizer](./10-visualizer-overlay.md)

---
*Last verified against Peekaboo @ `b514feabeaf1cb1fd40d031d8de97984e3391cce`*
