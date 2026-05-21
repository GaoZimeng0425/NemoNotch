---
summary: 'Use AXorcist to safely traverse the macOS Accessibility tree, focus elements, and avoid stale element reference errors.'
read_when:
  - 'implementing UI automation that finds and interacts with elements via Accessibility APIs'
  - 'troubleshooting kAXErrorInvalidUIElement errors or focus operations disrupting user workflow'
---

# 06 · AXorcist 元素查找 + Focus

## TL;DR

macOS Accessibility API(AX)的原始接口繁琐且易出错:元素引用随窗口状态改变而失效,app 解析需要处理名称/bundleId/PID 多种形式,focus 操作不当会打断用户工作流。AXorcist 将低层细节封装为类型安全的 `Element`/`AXApp`/`AXWindowResolver` 等 API,消费方只需声明"找什么"而非"怎么找"。核心模式:用 `AXApp(runningApp).element` 进入 AX 树,通过 `children()`/`role()`/`title()` 遍历匹配目标元素,配合 `windowIdentityService.findWindow(byID:)` 在操作前后刷新引用以防 stale。关键陷阱:缓存 `Element` 引用后再操作会触发 `kAXErrorInvalidUIElement`(-25202),每次操作前必须重新 query。

## Peekaboo 在哪里实现

- 模块:`AXorcist/`(submodule)+ `Core/PeekabooAutomationKit`(消费方)
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Utilities/FocusUtilities.swift:178` — 注释"AX handles can go stale after activation",刷新 element 引用的实现范本
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/WindowManagementService+Resolution.swift:51` — `WindowTarget` 枚举驱动 app resolving 多 strategy 分支
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/AXTreeCollector.swift:64` — `collect(window:deadline:budget:)` 展示带预算/deadline 的树遍历用法
- 关键文件:`Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit/Services/UI/TypeService+TargetResolution.swift:87` — `AXApp(frontApp).element` 进入 AX 树后按 role+label 递归匹配
- 相关 docs:`docs/focus.md`、`docs/application-resolving.md`、`docs/automation.md`

## 设计动机(Why)

macOS 的裸 AX API(`AXUIElementRef`)有几处典型坑:1)C 函数返回 `AXError` 枚举,稍不注意就漏检,错误静默传播;2)`AXUIElementRef` 本质是一个"此刻有效"的句柄,窗口激活、最小化或 Space 切换后句柄可能立即失效,后续操作会返回 `-25202`;3)app 解析只支持 PID,但 CLI/脚本场景用户输入的是 app 名或 bundle ID,需要自行转换;4)focus 操作如果直接调 `activate()` 会切走用户正在操作的 app。AXorcist 把以上问题统一收进 submodule,消费方得到类型安全的 Swift API。

## 核心模式(Pattern)

### 1. 进入 AX 树:AXApp → Element

```swift
// 从 NSRunningApplication 获取 app 根节点
let appElement = AXApp(runningApp).element   // 类型: Element
let windows = appElement.windows()           // [Element]?
let children = someElement.children()        // [Element]?
```

`AXApp` 是进入 AX 树的唯一入口,保持在 `@MainActor` 上下文内调用。

### 2. App Resolving 多 strategy

根据 `WindowManagementService+Resolution.swift:51` 中 `WindowTarget` 枚举的实现,四种 strategy 按精确度排列:

| Strategy | 适用场景 | 注意点 |
|---|---|---|
| `.frontmost` | 快速获取当前 app | 用户切 app 后结果变 |
| `.application(bundleId/name)` | 脚本化操作,名称/ID 已知 | 同名多实例会取第一个 |
| `.windowId(cgWindowID)` | snapshot 跨步骤复用 | 最稳定,窗口存活期内唯一 |
| `.index(app, n)` | 按顺序访问窗口 | app 重排后 index 可能变 |

多实例 app(如多个 Terminal 进程)优先使用 PID 或 CGWindowID,避免 name/bundleId 匹配到错误实例。

### 3. 元素匹配:role + label 打分

`TypeService+TargetResolution.swift` 中 `resolveTargetElement` 的打分策略:identifier 完全匹配 +400,label 完全匹配 +300,value 完全匹配 +200,以此类推。消费方需要类似逻辑时可以直接参照此模式,不要依赖固定数组下标或深度路径——AX 树结构随 app 版本可变。

```swift
// 递归匹配文本域示例(TypeService+TargetResolution.swift:82)
let appElement = AXApp(frontApp).element
if let field = searchTextFields(in: appElement, matching: query) {
    // 使用 field,不要缓存,用完即丢
}
```

### 4. Focus 保护:不抢用户焦点

`FocusUtilities.swift` 中 `FocusManagementService` 的三层保护:

1. **前置检查**:先确认窗口存在(`windowExists(windowID:)`)再操作
2. **激活后刷新**:activate 后必须重新 `findWindow(byID:)` 获取 refreshed handle(见第 201 行)
3. **后台模式**:`--focus-background` / `hotkey` 的 background delivery,向目标进程发事件而不切换前台 app

```swift
// 两步式 element 引用(FocusUtilities.swift:178-207)
// 步骤 1:激活前先拿 initial handle 确认 app
guard let initialHandle = windowIdentityService.findWindow(byID: windowID) else { ... }
// 步骤 2:activate 后重新 query,防 stale
guard let refreshedHandle = windowIdentityService.findWindow(byID: windowID, in: runningApp) else { ... }
try await focusWindowElement(refreshedHandle.element, ...)
```

### 5. AX 树遍历 Budget

`AXTreeCollector.swift:64` 的 `collect(window:deadline:budget:)` 接受 `AXTraversalBudget`(maxDepth / maxElementCount / maxChildrenPerNode)和一个 `deadline: Date`。新项目复用此模式时:设 deadline 防止 AX 慢应用卡死,设 budget 防止树节点爆炸。

## 新项目落地步骤(How to apply)

1. **添加 AXorcist 为 submodule**,在 `Package.swift` 中引入 `.product(name: "AXorcist", package: "AXorcist")`,并在消费文件顶部 `import AXorcist`。
2. **请求 Accessibility 权限**后,使用 `AXApp(runningApp).element` 获取 app 根节点,所有 AX 调用保持在 `@MainActor` 上。
3. **实现 app resolving 函数**,优先接受 bundleId 或 PID 参数,内部用 `NSWorkspace.shared.runningApplications` 查找 `NSRunningApplication`,再构造 `AXApp`。
4. **按需遍历 AX 树**时传入 `deadline`(建议 3–5 秒)和 `AXTraversalBudget`,在循环前检查 `Task.isCancelled` 和 `Date() < deadline`。
5. **Focus 操作前**调用 `windowExists(windowID:)` 确认窗口存在;激活 app 后**重新 query** element 引用,不复用激活前的 handle。
6. **操作完成后**,如需恢复 frontmost app,在操作前用 `NSWorkspace.shared.frontmostApplication` 记录原 app,操作后调用其 `activate()` 还原。
7. **错误处理**:区分 `axElementNotFound`(AX 树中找不到,通常需要重新遍历)和 `windowNotFound`(CGWindowID 已失效,需要重新 resolve app)两类错误,分别给出对应的降级路径。

## 常见陷阱(Pitfalls)

- **缓存 AX Element 引用后再操作 — 可观测信号:`kAXErrorInvalidUIElement`(-25202)**。AX element 句柄在窗口激活、切 Space、最小化后会立即失效,对失效句柄调用 `performAction`/`children()` 等方法会返回该错误码。`FocusUtilities.swift:178` 注释明确写道:"AX handles can go stale after activation"并在第 201 行重新 query 了 refreshedHandle。处理方式:将 element 视为一次性句柄,每次操作前重新从 `AXApp` 向下 query,不要将 `Element` 存进成员变量跨操作复用。

- **不设 deadline/timeout 导致主线程卡死 — 可观测信号:UI 出现彩虹转圈 / 进程 spin**。部分 app(如 Electron 应用)的 AX 响应极慢,`children()` 可能阻塞数秒。`AXTreeCollector.swift:98` 每次递归前都检查 `Date() < deadline`。处理方式:所有 AX 查询包裹在带 deadline 的循环里,超时后抛出 `FocusError.timeoutWaitingForCondition` 而非无限等待。

- **多实例 app 用 name/bundleId resolving 选错进程 — 可观测信号:操作发生在错误的 app 窗口上**。`--app Terminal` 在两个 Terminal 进程同时运行时会命中第一个,可能不是目标。`docs/application-resolving.md` 建议脚本场景"Use PIDs for precision"。处理方式:多实例场景改用 PID 或 CGWindowID 精确定位,参照 `WindowManagementService+Resolution.swift:51` 中 `.windowId(id)` 分支。

- **直接 activate 抢夺焦点破坏用户工作流 — 可观测信号:用户报"操作后我的窗口被切走了"**。`docs/focus.md` 专门提供了 `--focus-background` 选项,通过 process-targeted event 投递而非激活 app。处理方式:不需要用户感知的操作(发快捷键、后台写值)优先使用 background delivery,仅需要前台 focus 时才走完整的 activate → verify 流程。

## 延伸阅读

- Peekaboo:`docs/focus.md`、`docs/application-resolving.md`、`docs/automation.md`、`AXorcist/` submodule
- Apple:[Accessibility for Developers](https://developer.apple.com/accessibility/)、[AXUIElement Reference](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- 其它 playbook:[05 · 权限三态状态机](./05-permissions-state-machine.md)、[07 · CGEvent 拟真输入](./07-cgevent-input-synthesis.md)、[10 · Visualizer 屏上 overlay](./10-visualizer-overlay.md)

---
*Last verified against Peekaboo @ `d864f2a14ceae324bcab9e8b18b44d75e5893785`*
