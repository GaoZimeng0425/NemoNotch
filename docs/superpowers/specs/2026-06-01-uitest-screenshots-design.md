# NemoNotch UITest 截图方案设计

**日期**: 2026-06-01
**分支**: `feature/uitest-screenshots`
**方案**: B —— `--uitest` 自驱动 + mock 种子 + `screencapture` 裁切(不新建 Xcode target、不改 pbxproj)

## 背景与动机

NemoNotch 的 UI 已大幅迭代,README 的截图和文字都过时了。需要一条可重复执行的命令,产出全部 6 个 Tab 的确定性、营销级截图,再更新 README/README_CN。

参考项目 WorkPanel 能跑 XCUITest 截图,差别不在架构(两者都是 `MenuBarExtra` + `NSPanel` 的 `.accessory` 应用),而在于 WorkPanel:
1. 有专门的 `WorkPanelUITests` XCUITest target;
2. 有 `--uitest` 启动模式:内存库 + 注入确定性数据 + `applicationDidFinishLaunching` 里自动 `toggleBoard()` 弹出面板。

NemoNotch 缺这两样,且其内容依赖大量实时外部状态(真实日历/媒体/AI 会话/天气/agent),所以截图既不稳定也不好看。

### 为什么不照搬 XCUITest target(放弃方案 A)

- 工程是 `objectVersion = 77` + `PBXFileSystemSynchronizedRootGroup`(Xcode 16 自动同步格式),手改 pbxproj 加整个 target 极易出错;Ruby `xcodeproj` gem 未安装,`xcodegen` 不管理本工程。
- 项目记忆明确:不要手改 pbxproj 加源文件(自动同步)。新建 target 比加文件更敏感。
- 刘海面板是 borderless `NSPanel` 浮层,XCUITest 的 `app.screenshot()` 对这种瞬态浮层未必抓得干净(可能抓整屏或抓不到浮层)。`screencapture -R` 裁切已知区域反而更干净可控。

方案 B 保留了 WorkPanel 方案里最有价值的部分(`--uitest` 自驱动 + mock 种子),只是用 `screencapture` 取代 XCUITest 截图,从而绕开 target 创建摩擦。

## 目标与成功标准

- [ ] 执行 `scripts/uitest-screenshots.sh` 一条命令,产出 6 张 `docs/images/tab-<name>.png`,各对应一个 Tab,内容为营销级 mock 数据。
- [ ] 截图过程不与正在运行的 `/Applications/NemoNotch.app` 实例冲突(端口/守护进程/面板叠影),截完恢复用户的运行实例。
- [ ] README.md / README_CN.md 用新图,且修正过时内容。
- [ ] `--uitest` 模式不污染真实数据、不发起真实网络/IPC/子进程。

## 设计

### 1) `--uitest` 启动模式(改 `NemoNotch/NemoNotchApp.swift`)

新增 `UITestMode`(轻量值类型或 enum):

```swift
enum UITestMode {
    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("--uitest") }
    /// 解析 --tab=<name>,缺省 .overview
    static var tab: Tab { /* parse --tab= */ }
}
```

`applicationDidFinishLaunching` 分叉:
- uitest 分支构建 service 时**跳过所有实时副作用**(见 §2),调用 `UITestSeeder.seed(...)` 灌入 mock(见 §3),然后:
  - `NSApp.activate(ignoringOtherApps: true)`
  - `coordinator.notchOpen(tab: UITestMode.tab, on: NSScreen.main)`
  - 让面板**保持打开**:uitest 下不安装 `EventMonitor` 鼠标跟踪、不启 3 秒 hotkey 自动关闭,保证 `screencapture` 期间面板稳定可见。

### 2) 副作用抑制

uitest 下若照常启动,会和已装运行实例抢 HookServer 端口(45831)、起 perl 媒体守护、连 WebSocket/HTTP。必须跳过:

| Service | 实时副作用 | uitest 处理 |
|---|---|---|
| `AICLIMonitorService` | `startServer()`(HookServer 占端口) | AppDelegate 分支不调用 |
| `OpenClawService` | `connect()`(WebSocket) | 不调用 |
| `HermesService` | `connect()`(HTTP) | 不调用 |
| `MediaAutomationPermissionMonitor` | `startProbing()` | 不调用 |
| `WeatherService` | 网络请求 | 不调用 `updateCity` |
| `SystemService` | 进程轮询 | 不启动轮询 |
| `MediaService` | **`init` 内**起 perl 守护 + 轮询 | 加 `init(uitest:)` / `disableLiveUpdates` 开关,只建对象不起守护 |
| `CalendarService` | `init` 内若已授权则 `fetchEvents` | 无害(种子会覆盖),必要时也加守卫 |

其余 service 的实时工作都由 AppDelegate 显式调用触发,uitest 分支不调即可。

### 3) Mock 种子层(新增 `NemoNotch/Helpers/UITestSeeder.swift`)

一个 `@MainActor` 函数接住所有 service,按 Tab 填营销级假数据。凡是 `private(set)` 或派生状态的(如 `CalendarService.multiDayEvents`、`AICLIMonitorService.activeSession`),在对应 service 上加一个最小的 `seedForUITest(...)` 入口(尽量收敛在 service 内部,保持封装)。

各 Tab 种子内容:

- **Overview**:`MediaService.playbackState` = 正在播放的歌(标题/歌手/专辑 + 内置示例封面 asset)+ 进度;`CalendarService` 授权=`.fullAccess` + 几条今日/多日事件;`WeatherService` 当前天气值。
- **AI Chat (claude)**:`AICLIMonitorService.activeSession` = 一个 `AISessionState`,含一段真实感 Claude 会话(几条 user/assistant 消息 + 工具调用)、token 统计、模型名,可带一个 subagent。
- **Agents**:`AgentMonitorRegistry` 注册 OpenClaw + Hermes 两个 mock monitor,各含几个活跃 agent。
- **Launcher**:固定一组应用格子(避免依赖真实已装应用)。
- **Pomodoro**:`PomodoroTimerService` 进行中计时(剩余时间饼)+ `TaskStore` 若干 TODO,带每项已完成番茄数。
- **System**:`SystemService` Top 5 进程 + CPU/RAM/电量汇总。

**示例封面图**:放一张内置 asset(纯色/渐变 + 文字),不引用真实版权图。

### 4) 截图脚本(新增 `scripts/uitest-screenshots.sh`)

1. 退出当前 `/Applications/NemoNotch.app` 运行实例(避免两个浮层叠影),记下以便恢复。
2. `xcodebuild` 出一个 Debug `.app`(含 `--uitest` 代码)到固定路径。
3. 对每个 tab ∈ [overview, claude, agents, launcher, pomodoro, system]:
   - 启动 `NemoNotch.app --uitest --tab=<tab>`
   - `osascript -e 'delay <n>'` 等开屏动画(避免 shell `sleep`,harness 限制)
   - `screencapture -x -R<固定区域>` 存 `docs/images/tab-<name>.png`
   - 退出该实例
4. 全部完成后重新打开 `/Applications` 实例,恢复原状。

**截取区域**:uitest 强制 `notchOpen(on: NSScreen.main)` + 已知几何(`NotchConstants.overviewOpenedWidth = 700` / `openedWidth = 560`,`openedHeight = 328`),区域确定,不依赖鼠标位置。裁紧到面板不透明区域;圆角外可能露一点桌面壁纸,可接受。Retina 下输出 @2x PNG。

### 5) 文档更新

- `README.md` / `README_CN.md`:2 张旧 hero 图换成 6 张 per-tab 图;修正过时内容:
  - **8 Tab → 6 Tab**(`Tab` enum 实为 overview/claude/agents/launcher/pomodoro/system)
  - **Overview 已合并 Media + Calendar + Weather**
  - **Swift 5 → Swift 6**
- `CLAUDE.md`:视需要小修(基本准确)。
- 按项目规范,新增的 macOS 技术点(`--uitest` 自驱动截图)同 commit 补进 `docs/macos-cookbook.md`。

## 受影响文件

- 改:`NemoNotch/NemoNotchApp.swift`(uitest 分叉、副作用抑制)
- 改:`NemoNotch/Services/MediaService.swift`(`init(uitest:)` 开关)
- 改:若干 service 增加 `seedForUITest(...)` 入口(CalendarService、AICLIMonitorService、AgentMonitorRegistry/mock monitor、PomodoroTimerService/TaskStore、SystemService、WeatherService 等,按需)
- 改:`NemoNotch/Notch/NotchCoordinator.swift`(uitest 下保持打开、不装 EventMonitor/自动关闭)—— 视实现确认
- 新增:`NemoNotch/Helpers/UITestSeeder.swift`
- 新增:示例封面 asset(Assets.xcassets)
- 新增:`scripts/uitest-screenshots.sh`
- 改:`README.md`、`README_CN.md`、`docs/macos-cookbook.md`、(必要时)`CLAUDE.md`

## 非目标(YAGNI)

- 不新建 XCUITest target、不做 `xcodebuild test` 自动化截图。
- 不做拖拽/交互的 UI 测试。
- 不为截图引入第三方依赖(cliclick、快照库等)。
- mock 不追求覆盖所有边界状态,只覆盖"好看的活跃态"。

## 风险与缓解

- **双实例叠影 / 端口冲突**:uitest 跳过 HookServer 等;脚本先退出运行实例、截完恢复。
- **`private(set)` 状态难注入**:在 service 内加最小 `seedForUITest`,保持封装而非放开属性。
- **面板保持打开**:uitest 下不走 EventMonitor/自动关闭路径,靠程序化 `notchOpen` 常驻。
- **多屏环境**:强制 `on: NSScreen.main`(内建刘海屏)统一几何。
- **Debug-only 代码混入 Release**:种子层与 `--uitest` 分支用 `#if DEBUG` 或运行时 `UITestMode.isActive` 守卫,确保正常启动零影响。
