---
summary: '应用数据布局与路径安全：~/.appname/ 下 sqlite/logs/config 的组织惯例，以及防路径逃逸的 standardizedFileURL 前缀校验。'
read_when:
  - '规划 app 的持久化目录结构（日志、任务、历史、配置）'
  - '接受外部或 AI 提供的文件路径时做安全校验'
  - '决定用 ~/.appname/ 还是 ~/Library/Application Support/'
sources: ['I-18']
last_verified: { peekaboo: 'n/a', nemonotch: 'fe4e9e5' }
---

# 应用数据路径与布局

## TL;DR

NemoNotch 把所有运行时数据放在 `~/.NemoNotch/`，用子目录区分职责（`logs/`、`tasks.json`、`pomodoro-history.json`）。接受外部或 AI 提供的路径时，必须先 `standardizedFileURL` 再做包根前缀校验，防止 `../../../etc/passwd` 类路径逃逸。

---

## 可复用模式

### 模式 1 · ~/.appname/ 数据目录布局

NemoNotch 实际数据布局：

```
~/.NemoNotch/
├── logs/               # CocoaLumberjack 日志，按日轮转，保留 7 天
├── tasks.json          # TaskStore 持久化 TODO 列表
└── pomodoro-history.json  # PomodoroHistoryStore append-only 历史
```

惯例：
- 后台/CLI 工具用 `~/.appname/`（比 `~/Library/Application Support/` 更易调试，`ls` 可见）
- GUI 应用向用户暴露的数据用 `~/Library/Application Support/{BundleIdentifier}/`（符合 macOS 惯例，Time Machine 自动备份）
- 日志单独子目录，便于 `tail -f` 和清理
- append-only 历史记录用独立文件，防止全量覆写导致数据丢失

### 模式 2 · 路径安全校验（防逃逸）

任何接受外部或 AI 提供路径的地方，必须先 `standardizedFileURL` 再做包根前缀校验（来自 Ironsmith `AgentArtifacts.swift`）：

```swift
// AgentArtifacts.swift — packageFileURL(_:)
let root = packageRootURL.standardizedFileURL
let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                                    : root.appendingPathComponent(path)
let resolved = candidate.standardizedFileURL          // 解析 .. 和符号链接
guard resolved.path == root.path ||
      resolved.path.hasPrefix(root.path + "/") else {
    throw AgentFileError.pathEscapesPackage(path)     // 逃出包根 → 拒绝
}
guard resolved.path != root.path else {
    throw AgentFileError.pathIsPackageRoot            // 不许碰根本身
}
```

`standardizedFileURL` 解析 `..` 和符号链接；前缀检查确保路径在包根内；不许操作根目录本身。`ToolVersionBackupClient` 复用相同检查（`AGENTS.md:147`）。

### 模式 3 · TaskStore 测试隔离

`TaskStore(fileURL:)` 接受显式路径参数，测试和 UITest 模式下传入临时文件：

```swift
// UITestSeeder.swift 中
TaskStore(fileURL: FileManager.default.temporaryDirectory
    .appendingPathComponent("uitest-tasks-\(UUID()).json"))
```

这样 seeding 操作永远不会污染真实的 `~/.NemoNotch/tasks.json`。凡是有持久化副作用的 store，都应支持注入路径参数。

### 模式 4 · 路径常量集中管理

不在各处硬编码 `"~/.NemoNotch/"`，统一收到一个 `Paths` 枚举或命名空间：

```swift
// 参考模式（Ironsmith IronsmithPreferenceKeys 思路）
enum NemoNotchPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".NemoNotch")
    static let logs = root.appendingPathComponent("logs")
    static let tasks = root.appendingPathComponent("tasks.json")
    static let pomodoroHistory = root.appendingPathComponent("pomodoro-history.json")
}
```

---

## 锚点（file:line）

| 锚点 | 路径 |
|------|------|
| 路径安全校验 | `AgentArtifacts.swift`（Ironsmith 仓库，`packageFileURL(_:)`） |
| 备份路径校验 | `ToolVersionBackupClient.swift`（Ironsmith 仓库，`AGENTS.md:147`） |
| TaskStore 文件 URL 注入 | `NemoNotch/Helpers/UITestSeeder.swift`（uitest 路径隔离） |
| 日志目录配置 | `NemoNotch/Services/LogService.swift`（`~/.NemoNotch/logs/`） |
| TaskStore 持久化 | `NemoNotch/Services/TaskStore.swift`（`~/.NemoNotch/tasks.json`） |
| PomodoroHistoryStore | `NemoNotch/Services/PomodoroHistoryStore.swift`（`~/.NemoNotch/pomodoro-history.json`） |

---

## Pitfalls

**P1：路径未经 standardizedFileURL 直接做字符串前缀匹配**
`path.hasPrefix(root.path)` 在路径中含 `..` 或符号链接时不可靠。必须先 `standardizedFileURL` 解析后再比较。

**P2：根目录自身未被排除**
`resolved.path == root.path` 的 guard 缺失会允许删除/覆盖包根目录本身。

**P3：测试写入真实用户数据目录**
TaskStore、PomodoroHistoryStore 等在测试/UITest 中若未注入临时路径，会污染 `~/.NemoNotch/`，且测试之间互相干扰。凡有持久化副作用的 store 必须支持路径注入。

**P4：~/.appname/ 不自动创建**
`FileManager.createDirectory(at:withIntermediateDirectories:)` 需要在首次写入前调用，`withIntermediateDirectories: true` 保证幂等。

---

## 落地 Checklist

- [ ] 规划数据目录：根据 CLI/菜单栏 vs GUI 选 `~/.appname/` 或 `~/Library/Application Support/`
- [ ] 路径常量集中：新建 `Paths` 枚举，不散落硬编码字符串
- [ ] 首次写入前创建目录：`try FileManager.default.createDirectory(at:withIntermediateDirectories: true)`
- [ ] 接受外部路径时：`standardizedFileURL` → 前缀校验 → 排除包根自身
- [ ] 持久化 store 支持路径注入参数，供测试/UITest 使用临时目录
- [ ] 日志目录独立，支持轮转（CocoaLumberjack `DDFileLogger`）

---

## 延伸阅读

- [../project-layout/](../project-layout/) — 工程目录结构与模块划分
- [../logging/](../logging/) — CocoaLumberjack 配置，日志轮转与保留策略
- [../testing/](../testing/) — 测试中的依赖注入与临时路径隔离
