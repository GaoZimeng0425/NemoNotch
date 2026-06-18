---
summary: '持久化选型:SwiftData @Model/ModelContainer/迁移(Ironsmith)vs UserDefaults + ~/.NemoNotch/*.json(NemoNotch),按数据形态/规模选,不二选一。'
read_when:
  - '新功能需要持久化状态,决定用 SwiftData 还是 UserDefaults/JSON 文件'
  - '设计 SwiftData @Model 类型、容器初始化和字段迁移'
  - '设计 JSON 文件持久化（路径规范、原子写入、测试隔离）'
  - 'UserDefaults didSet 模式与 @AppStorage 的适用边界'
sources:
  - 'I §6 持久化(SwiftData)与数据安全'
  - 'I §4 状态管理与所有权边界'
  - 'N §17.5 Settings persistence'
  - 'N CLAUDE.md TaskStore / PomodoroHistoryStore'
last_verified:
  nemonotch: 'fe4e9e5'
  ironsmith: 'principles 文档 §6/§4'
---

# 持久化选型

## TL;DR

两种方式都在生产中验证，按数据形态和规模选择：

| 场景 | 推荐方式 |
|---|---|
| 结构化实体、需要查询/关系/迁移、多处读写 | **SwiftData** |
| 少量键值配置、枚举偏好 | **`UserDefaults` + `didSet`** |
| 用户产生的列表数据（TODO、历史记录）、需要跨工具读写 | **JSON 文件**（`~/.AppName/*.json`） |
| 需要绑定到 SwiftUI 控件（直接） | **`@AppStorage`** |

不要为"保持一致"而强行统一：同一个 app 里 UserDefaults（偏好设置）、JSON（用户数据）、Keychain（凭证）可以共存。

---

## 可复用模式

### 选型 A：SwiftData（Ironsmith）

适用场景：
- 数据有明确结构（工具配置、model 配置、provider 配置）
- 需要按条件查询（`#Predicate`）
- 需要跨版本字段迁移（字段重命名、类型变更）
- 测试需要隔离（内存库）

#### 1. ModelContainer 创建

```swift
enum IronsmithModelContainerFactory {
    static func make(isRunningTests: Bool) throws -> ModelContainer {
        if isRunningTests {
            // 测试/预览：内存库，无磁盘 IO，互不干扰
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try ModelContainer(
                for: Tool.self, ModelConfig.self, ProviderConfig.self,
                configurations: config
            )
        }
        // 生产：默认路径（~/Library/Application Support/<BundleID>/）
        return try ModelContainer(for: Tool.self, ModelConfig.self, ProviderConfig.self)
    }
}
```

实践：
- **测试和预览统一用 `isStoredInMemoryOnly: true`**，每个测试独立，不污染本地数据。
- `ModelContainer` 在 `AppDelegate` 或 `ApplicationController.init` 中创建，作为生命周期与 app 一致的唯一实例。
- **坏库保护原则**（⚠️ Ironsmith 文档描述了此模式但当前代码未实现，落地时自己补）：容器创建失败时，先把 `sqlite/wal/shm` 备份到 `~/.appname/Backups/` 再重建，**永不静默删除用户数据**。

#### 2. @Model 类型与稳定标识符

```swift
@Model final class Tool {
    @Attribute(.unique) var id: UUID     // 主键：UUID，唯一约束
    var name: String
    var executableName: String
    var bundleIdentifier: String
    var sandboxEnabled: Bool
    var packageRootPath: String          // 存路径字符串，派生 URL
    var createdAt: Date
    var updatedAt: Date
}

// 派生 URL：不存 URL，存字符串，按需派生
extension Tool {
    var packageRootURL: URL {
        URL(fileURLWithPath: packageRootPath, isDirectory: true)
    }
    var packageManifestURL: URL {
        packageRootURL.appendingPathComponent("Package.swift")
    }
}
```

字段迁移（重命名）：
```swift
// 旧字段名 baseURLTemplate → 新字段名 baseURLString
@Attribute(originalName: "baseURLTemplate")
var baseURLString: String
```

稳定标识符规范：
- **主键用 UUID**（`@Attribute(.unique) var id: UUID`）。
- **字段重命名用 `@Attribute(originalName:)`**，不加会在升级时丢失已有数据。
- 约定常量集中放（如 `ProviderConfig.localProviderIdentifier = "local"`），不要在多处硬编码。

#### 3. Repository 层（包装持久化访问）

```swift
// Repository 只做数据访问，不发网络，不起进程
struct ToolRepository {
    let modelContext: ModelContext

    func fetchAll() throws -> [Tool] {
        try modelContext.fetch(FetchDescriptor<Tool>())
    }

    func insert(_ tool: Tool) {
        modelContext.insert(tool)
    }

    func delete(_ tool: Tool) {
        modelContext.delete(tool)
    }
}
```

- **`remoteModels`（provider 发现来的模型）禁止写入 SwiftData**，它们是瞬时数据，只存内存（`AGENTS.md:63`）。
- SwiftData 只存 `persistedModels`（可安装的本地模型）和用户显式保存的配置。

---

### 选型 B：UserDefaults + JSON 文件（NemoNotch）

适用场景：
- 少量键值偏好（默认 Tab、启用的 Tab 集合、主题）→ **UserDefaults + didSet**
- 用户生成的列表数据（TODO 任务、Pomodoro 历史）→ **JSON 文件**

#### 1. UserDefaults + didSet（AppSettings 模式）

```swift
@MainActor @Observable
final class AppSettings {
    var defaultTab: Tab {
        didSet {
            UserDefaults.standard.set(defaultTab.rawValue, forKey: Keys.defaultTab)
        }
    }

    var enabledTabs: Set<Tab> {
        didSet {
            UserDefaults.standard.set(enabledTabs.map(\.rawValue), forKey: Keys.enabledTabs)
        }
    }

    init() {
        // init 中赋值不触发 didSet，无回写循环
        defaultTab = Tab(rawValue: UserDefaults.standard.string(forKey: Keys.defaultTab) ?? "") ?? .overview
        // …
    }

    private enum Keys {
        static let defaultTab = "defaultTab"
        static let enabledTabs = "enabledTabs"
    }
}
```

键名集中到私有枚举，不散落硬编码字符串。`didSet` 适合轻量键值；**不要在 `didSet` 里放网络请求或重型序列化**（SwiftUI binding 拖拽期间每帧触发）。

`@AppStorage` 等价写法（更简洁，适合直接绑定控件）：
```swift
@AppStorage("defaultTab") var defaultTab: String = Tab.overview.rawValue
```

**`@AppStorage` 与 `@Observable` 不能直接组合**：`@AppStorage` 是 `@Observable` 宏无法追踪的属性包装器。需要两者时，在 `@Observable` class 内手动读写 UserDefaults（`didSet` 模式），而不是用 `@AppStorage`。

#### 2. JSON 文件持久化

适合用户产生的结构化列表（任务、历史记录）：

```swift
// 路径规范：~/.NemoNotch/<name>.json
extension URL {
    static func nemoNotchData(_ filename: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".NemoNotch", isDirectory: true)
            .appendingPathComponent(filename)
    }
}

// 原子写入（写临时文件再 rename，防止中途崩溃产生损坏文件）
func save<T: Encodable>(_ value: T, to url: URL) throws {
    let data = try JSONEncoder().encode(value)
    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(url.lastPathComponent + ".tmp")
    try data.write(to: tmp, options: .atomic)
    // .atomic 选项本身即原子替换，等价于 write to tmp + rename
}

// 读取时容忍文件不存在
func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
```

测试隔离：注入不同的文件 URL，避免测试污染真实数据：
```swift
// TaskStore 接受注入的 URL
final class TaskStore {
    private let fileURL: URL

    init(fileURL: URL = .nemoNotchData("tasks.json")) {
        self.fileURL = fileURL
    }
}

// 测试时注入临时目录
let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tasks-test.json")
let store = TaskStore(fileURL: tmpURL)
```

#### 3. 路径集中管理

```swift
enum NemoNotchPaths {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".NemoNotch", isDirectory: true)
    }
    static var tasks: URL { root.appendingPathComponent("tasks.json") }
    static var pomodoroHistory: URL { root.appendingPathComponent("pomodoro-history.json") }
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    static func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}
```

启动时调用 `NemoNotchPaths.ensureDirectoriesExist()`，后续所有写入不再需要判断目录是否存在。

---

### 两种方式对比

| 维度 | SwiftData | UserDefaults + JSON |
|---|---|---|
| **数据形态** | 结构化实体，有关系 | 键值偏好 / 扁平列表 |
| **查询能力** | `#Predicate` 灵活查询 | 无，只能全量读 |
| **迁移** | `@Attribute(originalName:)` 版本迁移 | 手动处理，需要代码迁移逻辑 |
| **测试隔离** | `isStoredInMemoryOnly: true` | 注入不同 URL / UserDefaults suite |
| **跨工具读写** | 需要相同 bundle / app group | JSON 文件直接可读，shell 脚本也能处理 |
| **数据规模** | 中大型（千条以上） | 小型（百条以下） |
| **沙箱兼容** | SwiftData 自动放到容器目录 | `~/.AppName/` 在沙箱中不可写，需迁移 |
| **依赖** | macOS 14+（SwiftData 稳定版） | 无额外依赖 |

---

## 锚点（file:line）

| 概念 | 锚点 |
|---|---|
| ModelContainer 创建 | `I §6`；`IronsmithModelContainerFactory.swift` |
| @Model Tool 类型 | `I §6`；`Tool.swift`、`ModelConfig.swift` |
| originalName 迁移 | `I §6`；`ProviderConfig.swift:baseURLString` |
| ProviderCatalog 路径集中 | `I §6`；`IronsmithPaths.swift`、`IronsmithPreferenceKeys.swift` |
| AppSettings didSet | `N §17.5`；`NemoNotch/Models/AppSettings.swift:19` |
| TaskStore JSON 文件 | `NemoNotch/Services/TaskStore.swift:5` |
| PomodoroHistoryStore | `NemoNotch/Services/PomodoroHistoryStore.swift:5` |

---

## Pitfalls

**SwiftData：**
1. **`remoteModels` 写入 SwiftData**：provider 发现的远程模型是瞬时数据，写入会造成垃圾积累和意外状态；只存 `persistedModels`。
2. **字段重命名不加 `@Attribute(originalName:)`**：升级时 SwiftData 视为新字段，旧数据丢失，无报错。
3. **测试/预览不用内存库**：测试互相污染，且会修改本地真实数据。
4. **坏库直接删除重建，不备份**：用户数据无法恢复，应先备份再重建。
5. **容器创建失败未处理**：`try?` 静默失败后，后续所有 `modelContext` 操作报 nil crash。

**UserDefaults + JSON：**
6. **`@AppStorage` 和 `@Observable` 混用**：`@AppStorage` 属性包装器无法被 `@Observable` 宏追踪，SwiftUI 不会响应变化。
7. **`didSet` 中放重型操作**：binding 拖拽期间每帧触发 `didSet`，网络请求或复杂序列化会卡主线程。
8. **JSON 文件非原子写入**：直接 `write(to:)` 不加 `.atomic`，中途崩溃产生损坏文件，下次启动无法读取。
9. **路径硬编码散落**：`~/.NemoNotch/tasks.json` 出现在多处，一处改动需同步多处；集中到 `Paths` 枚举。
10. **测试不注入独立 URL**：测试修改 `~/.NemoNotch/tasks.json`，影响本地真实数据，且测试间互相污染。
11. **沙箱下 `~/.AppName/` 不可写**：沙箱 app 的 home 是容器目录，`FileManager.default.homeDirectoryForCurrentUser` 返回容器 home，不是 `~`；路径规划时区分沙箱/非沙箱。

---

## 落地 Checklist

**SwiftData：**
- [ ] 测试用 `isStoredInMemoryOnly: true` 内存库
- [ ] 字段重命名用 `@Attribute(originalName:)` 而不是直接改名
- [ ] 主键用 UUID + `@Attribute(.unique)`
- [ ] 路径/约定常量集中到 `Paths`/`PreferenceKeys` 枚举
- [ ] 容器创建失败时有保护路径（备份 + 重建，不静默删除）
- [ ] `remoteModels` 不写 SwiftData

**UserDefaults + JSON：**
- [ ] 键名集中到私有枚举，不散落硬编码字符串
- [ ] `@AppStorage` 与 `@Observable` 不混用
- [ ] JSON 文件写入用 `.atomic` 选项（防崩溃损坏）
- [ ] 路径集中到 `Paths` 枚举，启动时 `ensureDirectoriesExist()`
- [ ] 可测试的 Store 接受注入的 URL 参数（默认值为生产路径）
- [ ] 了解沙箱对文件路径的影响

---

## 延伸阅读

- [`state-ownership-and-di.md`](./state-ownership-and-di.md) — Repository 层职责与禁止事项
- [`../keychain/`](../keychain/) — 凭证（API key）的持久化选型（Keychain 而不是 UserDefaults/JSON）
- [`../build-release/`](../build-release/) — 应用数据路径规范（沙箱 vs 非沙箱）
- [`../ipc/`](../ipc/) — JSON 文件与外部工具的数据交换（hook installer、配置文件读写）
