---
summary: 'macOS 原生应用开发知识库总入口:按系统区块组织的可复用 playbook + 领域模块 + NemoNotch 专属速查。'
read_when:
  - '开始一个新的 macOS 应用,想按"我要做哪个系统能力"定位知识'
  - '查某个 macOS 子系统(窗口/权限/媒体/IPC…)的可复用模式与陷阱'
  - '回顾跨项目冲突当初是怎么裁决的'
---

# macOS 开发知识库

## 这是什么

从多个真实 macOS 项目(Peekaboo / NemoNotch / Ironsmith / Raycast)提炼、**按 macOS 开发区块**组织的可复用知识库。每个区块是跨项目去重融合后的统一结论;领域模块保留不属系统区块的专门主题;`macos-cookbook.md` 保留 NemoNotch 专属的 `file:line` 精确锚点。

## 怎么用

- **新建项目**:从「基础设施」区块起步,按需引入「系统集成」与「视觉交互」。
- **补某能力**:直接进对应区块文件夹,每篇自带 Pitfalls 与落地 checklist。
- **查精确锚点**:区块篇引用 `macos-cookbook.md` 取 NemoNotch 源码 `file:line`。

## 区块树

### 基础设施
- [project-layout/](./project-layout/) — 模块/SPM 分层、依赖方向、增量构建隔离
- [concurrency/](./concurrency/) — Swift 6 严格并发、@MainActor、Sendable 边界
- [logging/](./logging/) — CocoaLumberjack/LogService(主)+ OSLog 底层与适用边界
- [error-handling/](./error-handling/) — 三层错误:域错误→跨域包装→跨进程序列化

### 系统集成
- [private-api/](./private-api/) — dlopen/dlsym 私有框架加载
- [events-hotkeys/](./events-hotkeys/) — 全局事件监听、CGEvent 拟真输入、热键
- [media/](./media/) — MediaRemote、NowPlayingCLI daemon、ScriptingBridge reconcile
- [system-sensing/](./system-sensing/) — CPU/内存/磁盘采样、亮度、电量
- [accessibility/](./accessibility/) — AX 树遍历 + Focus、Dock 角标
- [screen-capture/](./screen-capture/) — ScreenCaptureKit、窗口枚举、Spaces
- [permissions/](./permissions/) — TCC 状态机、PermissionCard never-auto-prompt、Info.plist 陷阱
- [ipc/](./ipc/) — Unix socket、subprocess、HookServer + hook installer
- [keychain/](./keychain/) — Keychain 基础、cdhash-gated 静默读

### 视觉与交互
- [window/](./window/) — NSWindow/NSPanel、notch 面板、多屏 overlay、completion flash/glow
- [swiftui/](./swiftui/) — SwiftUI 模式、AppKit 桥接、Liquid Glass、状态驱动紧凑 UI

### 工程实践
- [architecture/](./architecture/) — @Observable 服务层、DI、单一真相源 store、protocol-first
- [testing/](./testing/) — 权限敏感测试 gating、Swift Testing
- [build-release/](./build-release/) — 签名/公证/DMG、应用数据路径、增量构建、UI-test harness

## 领域模块(非系统区块)

- [ai-codegen/](./ai-codegen/) — AI 代码生成管线(Ironsmith):prompt 工程、输出清洗、编译诊断解析、修复循环
- [native-feel/](./native-feel/) — WebView 跨平台 native-feel skill(Raycast);**技术栈不同于原生 macOS**,适用于跨平台 WebView app
- [design-system/](./design-system/) — NemoNotch Warm Noir 视觉系统(单 OS 原生 SwiftUI 的品牌视觉)
- [macos-cookbook.md](../macos-cookbook.md) — NemoNotch 专属 `file:line` 速查地图

## 冲突裁决记录

跨项目融合时遇到的冲突与最终裁决(可追溯)。

| 区块 | 冲突 | 裁决 | 日期 |
|---|---|---|---|
| logging | swift-log(P01)/ OSLog(P03)/ CocoaLumberjack(N)/ 自研(I) | CocoaLumberjack 为主、OSLog 作底层;修 P01 swift-log 离群描述 | 2026-06-18 |
| permissions | "三态"标题 vs 五态代码 vs 七态图(P05) | **七态完整模型**;注明 Swift 枚举折成 5 个 case | 2026-06-18 |
| testing | 裸 `-D`(P11)不生效;env 门控 key 不一致致 input 测试永不启用 | 统一 `-Xswiftc -D`;env 用通用泛化名 `RUN_AUTOMATION_TESTS` | 2026-06-18 |
| keychain | accessibility 常量 `ThisDeviceOnly`(I)vs 示例未设(N) | 推荐 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` | 2026-06-18 |
| screen-capture | `SCScreenshotManager` 12.3+ vs 14+(P08 自相矛盾) | 取 14+(正确) | 2026-06-18 |
| events-hotkeys | 对数正态下限钳制 0.2× vs 0.25×(P07) | 取实测代码值 0.2× | 2026-06-18 |
| window | overlay level `.screenSaver`(P10)vs `.floating`(P09) | 并列两种 + 标注适用场景,不强裁 | 2026-06-18 |
| swiftui | accent 系统色(R)vs 固定橙(D);spring;web toast vs HUD toast | 并列 + 标注适用场景,不强裁 | 2026-06-18 |
| architecture | DI 闭包client(I)vs protocol-first(N);SwiftData(I)vs UserDefaults/JSON(N) | 并列两种选型 + 按场景选,不强裁 | 2026-06-18 |

## 源项目缩写

各篇 frontmatter 的 `sources` 与正文锚点用以下缩写标注融合来源:

- **P** = Peekaboo(原 `macos/` playbook 套件;`P03` = 其日志篇)
- **N** = NemoNotch(`macos-cookbook.md`;`N §7` = cookbook 第 7 节)
- **I** = Ironsmith(`I-20` = 其原则文档第 20 章;管线部分见 [ai-codegen/](./ai-codegen/))
- **R** = Raycast([native-feel/](./native-feel/))
- **D** = NemoNotch 设计系统([design-system/](./design-system/))

## 源码锚定版本

- **NemoNotch(N / D)**:锚定 commit `fe4e9e5`;精确 `file:line` 见各篇 + [`macos-cookbook.md`](../macos-cookbook.md)。
- **Peekaboo(P)**:来自原 `macos/` playbook 套件,各篇当初在**不同 commit** 上各自校验,故各区块 frontmatter 的 `last_verified.peekaboo` SHA 不统一——这是历史事实,非笔误;以各篇自记的 SHA 为准。
- **Ironsmith(I)**:来自 principles 文档(无 commit SHA),锚点尽量指向 Ironsmith 实际源文件名。
- **Raycast(R)**:见 [`native-feel/`](./native-feel/) 各篇自记来源。

---
*区块树由 Peekaboo / NemoNotch / Ironsmith / Raycast 提炼融合。各篇 frontmatter 记 `sources` 与 `last_verified`。*
