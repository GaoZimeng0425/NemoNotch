---
summary: '用 AXorcist 类型安全地遍历 AX 树、执行 Focus 保护操作,以及防范 stale element 句柄失效。'
read_when:
  - '驱动非原生 UI(Electron/浏览器/终端)的生产代码'
  - '需要 app resolving、element query、或 focus 保护的自动化任务'
  - '遭遇 kAXErrorInvalidUIElement(-25202) 或 AX query 超时卡死'
sources: ['P06']
last_verified:
  peekaboo: 'b8c6c48bc7e788949421b8aa48655bcbb491b348'
  nemonotch: 'fe4e9e5'
---

# AX 树遍历与 Focus 保护

## TL;DR

macOS Accessibility API 的原始 C 接口(`AXUIElementRef`)有三大无声陷阱:句柄随窗口激活随时失效、默认 6 秒超时阻塞主线程、属性名 stringly-typed 拼错不报错。AXorcist 把这些封装为 Swift-native 的类型安全 API。

核心三元组:
1. **Query DSL** — `AXApp(runningApp).element` 进树,`children()` / `role()` / `title()` 声明式匹配
2. **Focus 保护** — 操作前快照 `frontmostApplication`,操作后还原;激活后必须重新 query
3. **Deadline guard** — 每次递归前 `Date() < deadline`,超时 throw 而非阻塞

## 可复用模式

### Pattern 1 · 进入 AX 树

```swift
// WindowManagementService+Resolution.swift:91
let appElement = AXApp(runningApp).element   // Element (Sendable 包装)
let windows    = appElement.windows()        // [Element]?
let children   = someElement.children()     // [Element]?
let role       = someElement.role()         // String?  e.g. "AXButton"
let title      = someElement.title()        // String?
```

`AXApp` 是进入 AX 树的唯一入口。所有 AX 调用必须在 `@MainActor` 或 `DispatchQueue.main` 上执行。

### Pattern 2 · App Resolving 三级优先

精确度降序:`pid` > `bundleId` > `name`。

```swift
// ApplicationService+Discovery.swift:108  findApplication
func resolveApp(bundleID: String? = nil, name: String? = nil, pid: pid_t? = nil)
    throws -> NSRunningApplication
{
    if let pid, let app = NSRunningApplication(processIdentifier: pid) { return app }
    let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
    if let bundleID,
       let app = running.first(where: { $0.bundleIdentifier == bundleID }) { return app }
    if let name {
        let lower = name.lowercased()
        if let app = running.first(where: { ($0.localizedName ?? "").lowercased() == lower }) { return app }
        if let app = running.first(where: { ($0.localizedName ?? "").lowercased().contains(lower) }) { return app }
    }
    throw AXDriverError.appNotFound
}
```

| 场景 | 推荐 | 原因 |
|------|------|------|
| 单次操作 | `bundleId` / `name` | 简单直观 |
| 脚本化跨步骤 | `pid` | 窗口存活期内唯一 |
| 多实例 app | `pid` | `bundleId` 命中第一个,不一定是目标 |
| app 重启后 | 重新 resolve | PID 不持久 |

### Pattern 3 · 元素查找:role + label 打分

```swift
// TypeService+TargetResolution.swift:82  findTextFieldByQuery
@MainActor
private func searchTextFields(in element: Element, matching query: String) -> Element? {
    let role = element.role()?.lowercased() ?? ""
    if role.contains("textfield") || role.contains("textarea") {
        let label = element.label()?.lowercased() ?? ""
        let placeholder = element.placeholderValue()?.lowercased() ?? ""
        if label.contains(query) || placeholder.contains(query) {
            return element   // 用完即丢,不要存到成员变量
        }
    }
    return element.children()?.compactMap {
        searchTextFields(in: $0, matching: query)
    }.first
}
```

打分权重(TypeService 实现):identifier 完全匹配 +400,label 完全匹配 +300,value 完全匹配 +200。不要依赖固定下标或深度路径,AX 树结构随 app 版本可变。

### Pattern 4 · Deadline Guard(防卡死)

```swift
// AXTreeCollector.swift:98  collect(window:deadline:budget:)
func searchElement(in element: Element, deadline: Date, ...) -> Element? {
    guard Date() < deadline else { return nil }   // ← 每次递归前检查
    // ... 递归遍历
}
```

消费方包装器:

```swift
func queryWithDeadline<T>(deadline: Date, query: () throws -> T?) throws -> T {
    guard Date() < deadline else { throw AXDriverError.timeout }
    guard let result = try query() else { throw AXDriverError.elementNotFound }
    return result
}
```

### Pattern 5 · Focus 保护包装

```swift
// FocusUtilities.swift:178-207
func withFocusProtection(perform action: () async throws -> Void) async throws {
    let previousApp = NSWorkspace.shared.frontmostApplication
    var actionError: Error?
    do { try await action() } catch { actionError = error }

    if let prev = previousApp,
       NSWorkspace.shared.frontmostApplication?.processIdentifier != prev.processIdentifier {
        prev.activate()
    }
    if let err = actionError { throw err }
}
```

激活目标 app 后,**必须重新 query** element 句柄,不能复用激活前的句柄:

```swift
// FocusUtilities.swift:201
runningApp.activate()
// 等待 isActive…
guard let refreshedHandle = windowIdentityService.findWindow(byID: windowID, in: runningApp) else {
    throw AXDriverError.elementNotFound
}
```

### Pattern 6 · 非原生环境降级路径

**Electron / Chromium 系**(`AXSetValue` 返回 success 但字段没变):

```swift
// 1. AX setValue
try driver.setValue(element: inputElement, value: text)
if driver.getValue(element: inputElement) == text { return }   // 验证
// 2. AX click-focus + CGEvent cghidEventTap + ≥1ms 间隔
// 3. 坐标点击 + CGEvent(最脆弱)
```

相关文件:
- `ElementClassifier.swift:50` — Chromium/Tauri 把 clickable 内容藏进 `AXGroup`/`AXImage` 等容器
- `ElementDetectionWindowResolver.swift:102` — Chrome 多进程偶发空窗口列表,改用 `windowsWithTimeout()`
- `ElementDetectionService.swift:215` — 第一遍稀疏时触发 web focus fallback(`AXWebArea`)
- `DialogService+Resolution.swift:132` — Electron/Tauri 限制到 `focusedWindow`/`mainWindow` 防无边界遍历

**终端 Emulator**:PTY 缓冲区不是 AX 控件,`AXSetValue` 无效 → 改用 CGEvent 键盘合成或 osascript。

## 锚点(file:line)

| 描述 | 锚点 |
|------|------|
| AX 树入口 `AXApp(runningApp).element` | `WindowManagementService+Resolution.swift:91` |
| stale 引用注释 + 重新 query 范本 | `FocusUtilities.swift:178,201` |
| 带 deadline + budget 的树遍历 | `AXTreeCollector.swift:64,98` |
| `findTextFieldByQuery` role+label 匹配 | `TypeService+TargetResolution.swift:82` |
| Chrome 多进程空窗口列表 → `windowsWithTimeout()` | `ElementDetectionWindowResolver.swift:102,104` |
| Chromium/Tauri 容器角色 `supportedActionLookupRoles` | `ElementClassifier.swift:50` |
| 第一遍稀疏 → web focus fallback | `ElementDetectionService.swift:215` |
| Electron/Tauri dialog 限制子树范围 | `DialogService+Resolution.swift:132` |
| App resolving 三态决策 | `ApplicationService+Discovery.swift:108` |

所有路径均位于 `Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/` 下。

## Pitfalls

**P1 · 缓存 AX Element 跨操作复用 → `kAXErrorInvalidUIElement`(-25202)**
窗口激活、Space 切换、最小化后句柄立即失效。`FocusUtilities.swift:178` 注释明确写道"AX handles can go stale after activation"。
处置:将 `Element` 视为一次性句柄,每次操作前重新从 `AXApp` 向下 query;不要跨 `await` 点复用。

```swift
// ❌ 成员变量缓存 Element
var cachedButton: Element?

// ✅ 每次操作前重新 query
let appElement = AXApp(runningApp).element
let btn = findButton(in: appElement, label: "Search")
btn.performAction(.press)
```

**P2 · 不设 deadline 导致主线程卡死(Electron 慢响应)**
默认 AX messaging timeout 为 6 秒,`children()` 在 Electron 上可能阻塞数秒。
处置:`AXTreeCollector.swift:98` 每次递归前 `Date() < deadline`;对已知慢目标加大 queryTimeout 至 8-10 秒。

**P3 · name/bundleId resolving 多实例选错进程**
两个 Terminal 窗口同时运行时,`bundleId` 命中第一个,不一定是目标。
处置:多实例场景改用 `pid` 精确定位。

**P4 · activate 抢夺焦点破坏用户工作流**
`docs/focus.md` 提供了 `--focus-background` 选项。
处置:后台操作优先 background delivery;只在必须前台 focus 时走完整 `activate` + `withFocusProtection`。

**P5 · Electron AX 树误信(`setValue` 返回 success 但字段没变)**
Chromium AX bridge 对部分控件的 `AXSetValue` 总是报告成功但实际是只读的。
处置:操作后立即 `getValue` 读回对比,不一致则降级到 CGEvent 路径。

**P6 · 沙盒 app AX 限制 → `AXError -25204`**
沙盒 app 操作其它 app 的 AX 树会遇到 `-25204 kAXErrorCannotComplete`。
处置:检查 entitlements 是否含 `com.apple.security.automation.apple-events`。

**P7 · 权限检查不通过却静默成功**
`AXIsProcessTrusted()` 返回 false 时,AX 调用可能"成功"但返回空数据,极难排查。
处置:在 `UIAutomationDriver.init()` 加 `precondition(AXIsProcessTrusted(), ...)`,宁可崩溃也不静默失败。

## 落地 checklist

- [ ] 添加 AXorcist submodule,`Package.swift` 中声明依赖
- [ ] 启动时调用 `AXIsProcessTrusted()`,false 则弹引导对话框链接 Accessibility 偏好
- [ ] 实现 `UIAutomationDriver` 包装层,暴露 `bundleID`/`name`/`pid` 三态 resolving
- [ ] 注入 `AXDriverConfig { queryTimeout, elementExpiry }`,不硬编码超时值
- [ ] 所有会激活目标 app 的操作用 `withFocusProtection` 包裹
- [ ] 激活后重新 query element 句柄,不复用激活前的句柄
- [ ] 区分 `elementNotFound` vs `staleElement(-25202)`:前者扩大搜索,后者 `invalidateCache()` + 重新 query
- [ ] Electron 目标:操作后 `getValue` 验证,不一致降级 CGEvent
- [ ] `AXApp` 初始化和每次 `query` 前后加 `os.log` debug 日志,记录 app pid、role、耗时
- [ ] 定义 `UIAutomationDriving` 协议 + `MockUIAutomationDriver`,测试无需真实 AX 权限

## 延伸阅读

- [Dock 角标读取](./dock-badges.md) — AX API 的另一个典型用途
- [../permissions/](../permissions/) — AX 权限检测与引导的完整流程
- Apple 官方:[AXUIElement Reference](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- Peekaboo docs:`docs/focus.md`、`docs/application-resolving.md`、`docs/automation.md`
