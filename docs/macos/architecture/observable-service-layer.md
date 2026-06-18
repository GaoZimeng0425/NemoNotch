---
summary: '@Observable 服务层:Service 标准形态、AppDelegate 装配与所有权、@Environment 注入、LifecycleAware 激活、刷新节流。'
read_when:
  - '新建 macOS app,需要定义后台服务的标准结构'
  - '理解 AppDelegate 如何装配并注入所有服务'
  - '实现按需激活/停用服务(Tab 切换、面板显示/隐藏)'
  - '给高频刷新的服务加节流,避免不必要的网络或计算'
sources:
  - 'N §17.1 Service ownership in AppDelegate'
  - 'N §17.4 LifecycleAware'
  - 'N §17.5 Settings persistence'
  - 'N §15.1 Default service shape'
  - 'N §16.1 @Environment injection'
last_verified:
  nemonotch: 'fe4e9e5'
  ironsmith: 'principles 文档 §2/§4'
---

# @Observable 服务层

## TL;DR

所有后台服务遵循同一形态:`@MainActor @Observable final class`，在 `AppDelegate.applicationDidFinishLaunching` 中统一实例化、统一注入，UI 通过 `@Environment` 读取。服务不向外暴露 setter；SwiftUI 通过 `@Observable` 宏自动追踪属性变化并重绘。

---

## 可复用模式

### 1. 标准服务形态

```swift
@MainActor
@Observable
final class MediaService {
    // 所有可观察状态直接作为存储属性
    var playbackState = PlaybackState()
    var currentTrack: TrackInfo?

    // 不参与观察的私有依赖
    @ObservationIgnored private var timer: Timer?

    func togglePlayPause() { /* … */ }
}
```

规则：
- `@MainActor` 让所有属性修改和 UI 读取都在主线程，无需额外 `DispatchQueue.main` 跳转。
- `@Observable` 宏自动合成访问追踪；**不要混用 `@Published`**，会干扰宏的合成。
- **必须 `final`**：`@Observable` 宏在非 final 类上会产生误导性编译错误（错误信息指向宏展开内部）。
- 后台回调（Timer、NotificationCenter、DispatchSource）通过 `Task { @MainActor [weak self] in }` 回到主 actor 再修改状态。

### 2. AppDelegate 装配与所有权

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    // AppDelegate 是唯一拥有者：持有强引用，防止 ARC 释放
    private var coordinator: NotchCoordinator?
    private var settings: AppSettings?
    // … 其余服务

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 按依赖顺序实例化：被依赖的先创建
        let settings = AppSettings()
        let media = MediaService()
        let calendar = CalendarService()
        let aiMonitor = AICLIMonitorService()
        // … 其余服务

        let notchCoordinator = NotchCoordinator { coordinator, screen in
            AnyView(
                NotchView(screen: screen)
                    .environment(coordinator)
                    .environment(settings)
                    .environment(media)
                    .environment(aiMonitor)
                    // … 每个注入服务一行 .environment(_:)
            )
        }

        self.coordinator = notchCoordinator
        self.settings = settings

        // 热键依赖 coordinator，必须在 coordinator 创建后再注册
        setupHotkeys(coordinator: notchCoordinator, settings: settings)
    }
}
```

关键约束：
- **`setupHotkeys` 必须在 coordinator 创建之后调用**。热键闭包弱捕获 coordinator；若顺序颠倒，首次按键时 `weak coordinator` 为 nil，动作静默失效。
- AppDelegate 同时拥有所有服务，保证生命周期与应用一致。
- 新代码**不要**引入 `AppDelegate.shared` 全局单例访问模式（见 `N §17.2`）；需要跨对象通信时用闭包注入或 `@Environment`。

### 3. `@Environment` 注入与消费

```swift
// 消费端
struct NotchView: View {
    let screen: NSScreen
    @Environment(NotchCoordinator.self) var coordinator
    @Environment(MediaService.self) var mediaService
    @Environment(AppSettings.self) var appSettings
    // …
}
```

注意：
- 若某个 `@Environment` 在运行时缺失（祖先 View 没有 `.environment(_:)`），SwiftUI **会崩溃**，不会优雅降级。没有 `@Environment(T.self)?` 可选形式。
- 新式 `@Observable` + `@Environment` 与旧式 `@EnvironmentObject` 不兼容，不能混用于同一 View 树。
- 需要 binding 时：`body` 内写 `@Bindable var svc = svc`，再用 `$svc.property`。

### 4. `LifecycleAware` 按需激活

服务只应在对应 UI 可见时运行（如只在某个 Tab 打开时才启动定时器）：

```swift
@MainActor
protocol LifecycleAware: AnyObject {
    func setActive(_ active: Bool)
}

extension View {
    func activates(_ service: any LifecycleAware) -> some View {
        self
            .onAppear { service.setActive(true) }
            .onDisappear { service.setActive(false) }
    }
}
```

使用位置：
```swift
struct SystemTab: View {
    @Environment(SystemService.self) var systemService
    var body: some View {
        SystemTabContent()
            .activates(systemService)  // ← 挂在叶子 View，不要挂容器
    }
}
```

**`.activates` 必须挂在叶子消费 View**，不要挂容器。容器在面板打开期间始终 mounted，挂在容器上相当于永远激活，失去按需的意义。

### 5. `didSet` 持久化（AppSettings 模式）

```swift
@MainActor @Observable
final class AppSettings {
    var defaultTab: Tab {
        didSet {
            UserDefaults.standard.set(defaultTab.rawValue, forKey: "defaultTab")
        }
    }

    var enabledTabs: Set<Tab> {
        didSet {
            UserDefaults.standard.set(enabledTabs.map(\.rawValue), forKey: "enabledTabs")
        }
    }

    init() {
        // init 中的赋值不触发 didSet，不会产生回写循环
        self.defaultTab = Tab(rawValue: UserDefaults.standard.string(forKey: "defaultTab") ?? "") ?? .overview
        self.enabledTabs = /* 从 UserDefaults 读取 */
    }
}
```

`didSet` 在 `init` 期间不触发，不会产生初始化时的写回循环。`UserDefaults` 是内存级写入（延迟落盘），`didSet` 适合轻量键值，**不要在里面放网络请求或重型序列化**。

### 6. 刷新节流（高频服务）

对定期轮询的服务（天气、quota、系统采样）设置最小刷新间隔，避免多次触发堆叠：

```swift
private var lastRefresh: Date = .distantPast
private let throttle: TimeInterval = 60

func refreshIfNeeded() {
    guard Date().timeIntervalSince(lastRefresh) >= throttle else { return }
    lastRefresh = Date()
    Task { await fetchQuota() }
}
```

对于 `LifecycleAware` 服务，`setActive(true)` 时立即触发一次刷新，然后启动定时器；`setActive(false)` 取消定时器。

---

## 锚点（file:line）

| 模式 | 锚点 |
|---|---|
| 标准服务形态（15 个服务） | `N §15.1`；代表：`NemoNotch/Services/MediaService.swift:4-17` |
| AppDelegate 装配 | `N §17.1`；`NemoNotch/NemoNotchApp.swift:105-188` |
| `@Environment` 注入 | `N §16.1`；`NemoNotch/Notch/NotchView.swift:3-15` |
| `LifecycleAware` 协议 | `N §17.4`；`NemoNotch/Helpers/LifecycleAware.swift:6-20` |
| `AppSettings didSet` | `N §17.5`；`NemoNotch/Models/AppSettings.swift:19-52` |
| Ironsmith Store 形态 | `I §4`；`InferenceStore.swift`、`ModelSelectionStore.swift` |

---

## Pitfalls

1. **`@Observable` 忘写 `final`**：宏展开内部报错，提示信息与实际原因无关，难以定位。
2. **`@MainActor` 缺失**：属性赋值变成跨 actor hop，在 SwiftUI 热路径上增加调度延迟。
3. **混用 `@Published`**：`@Observable` 宏会失效或产生重复追踪，不要两者并用。
4. **`setupHotkeys` 在 coordinator 创建前调用**：热键闭包弱捕获的 coordinator 为 nil，动作静默失效，无报错。
5. **`@Environment` 缺失祖先注入**：运行时崩溃，无优雅降级，必须保证每个 `@Environment` 在祖先有对应 `.environment(_:)`。
6. **`.activates` 挂在容器**：容器始终 mounted，服务永远处于激活状态，失去节流意义。
7. **`didSet` 中放重型操作**：SwiftUI binding 拖拽期间每帧触发 `didSet`，重型操作会卡主线程。
8. **不在后台回调中 hop 回主 actor**：从 `NotificationCenter` block 或 `DispatchSource` 直接写 `@Observable` 属性，Swift 6 编译报错；必须用 `Task { @MainActor in }`。

---

## 落地 Checklist

- [ ] 服务声明为 `@MainActor @Observable final class`
- [ ] 不混用 `@Published`；内部计时器/队列依赖标 `@ObservationIgnored`
- [ ] AppDelegate 持有所有服务的强引用；`setupHotkeys` 在 coordinator 创建后调用
- [ ] 每个服务通过 `.environment(_:)` 注入，消费端用 `@Environment`
- [ ] 按需激活的服务实现 `LifecycleAware`，`.activates()` 挂在叶子 View
- [ ] 高频轮询服务加节流逻辑（`lastRefresh + throttle`）
- [ ] 后台回调统一 `Task { @MainActor [weak self] in }` 回主 actor
- [ ] 新代码不添加 `AppDelegate.shared` 全局访问

---

## 延伸阅读

- [`../concurrency/`](../concurrency/) — Swift 6 严格并发、`@unchecked Sendable`、`nonisolated(unsafe)` 用法
- [`state-ownership-and-di.md`](./state-ownership-and-di.md) — 状态所有权边界与 DI 选型
- [`single-source-store.md`](./single-source-store.md) — 多 provider 共享的中心 store 模式
- [`../swiftui/`](../swiftui/) — SwiftUI 模式、AppKit 桥接细节
