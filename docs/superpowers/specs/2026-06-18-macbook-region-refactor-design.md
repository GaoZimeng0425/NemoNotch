---
summary: '把 ../macbook/ 知识库全量重构成一棵按 macOS 开发区块组织的树,融合 Peekaboo / NemoNotch / Ironsmith / Raycast 四个来源,去重并裁决冲突。'
status: design
created: 2026-06-18
scope: ../macbook/（NemoNotch repo 之外的同级目录,非 git 仓库)
---

# macbook 知识库:按 macOS 区块全量重构 — 设计文档

## 1. 背景与目标

`../macbook/` 是一个个人 macOS 开发知识库,目前由四个来源项目的提炼物拼成,**按项目分散**:

| 现有路径 | 来源项目 | 性质 |
|---|---|---|
| `macos/`(01–12 + index) | Peekaboo | 编号 playbook 套件,按子系统组织 |
| `macos-cookbook.md`(2501 行) | NemoNotch | `file:line` 速查地图(已落后 live 版 240 行) |
| `ai-swift-app-development-principles.md`(23 章) | Ironsmith | 架构原则 + AI 代码生成管线 |
| `native-feel/`(SKILL + references + checklists) | Raycast | WebView 跨平台 native-feel skill |
| `design/`(warm-noir 等 3 篇) | NemoNotch | Warm Noir 视觉系统 |

**问题**:同一个 macOS 区块(权限、日志、并发、SwiftUI…)的知识分散在多个来源里,彼此**互相矛盾或重复**(见 §6 已知冲突清单)。按项目找知识,而不是按"我现在要解决的 macOS 问题"找。

**目标**:重构成**一棵按 macOS 开发区块组织的树**,让"我要做 X 系统能力"能直接定位到一个区块,区块内是**跨项目去重融合后的统一结论**,而非并列的多项目片段。

**非目标**:不改写各来源项目的源码;不为不存在的场景补内容;只重组与融合已有知识。

## 2. 核心决策(已与用户确认)

1. **全量重构**:所有文档拆散,按 macOS 区块重新归位成统一树。
2. **每区块合并成一篇视角**:同一区块的多项目内容**融合、去重**;不按项目分子文件(不要 `permissions/peekaboo.md` + `permissions/nemonotch.md`)。区块内可按**子主题**再分多个 md。
3. **硬冲突上报裁决**:无法机械融合的真冲突(如 logger 选型),**列出交用户判断**,不擅自取舍。
4. **logging 采用 CocoaLumberjack**:以 NemoNotch 的 `LogService`(`DDOSLogger` + `DDFileLogger`)为主线,OSLog 讲底层与"何时够用",Ironsmith DEBUG-only 诊断作对比。
5. **Ironsmith AI 管线 → 独立 domain**:`ai-codegen/`,不进区块树;只把其中可复用的 macOS 细节(签名/路径/SwiftPM)抽进区块。
6. **native-feel + design-system → 经验进区块 + 保留 domain**:把可复用经验抽进所属区块(native-feel 的原生约定、design-system 的样式),**同时**保留为独立 domain 模块。
7. **就地搬迁删除原文件**:完全并入区块树的 `macos/` 与 `principles` 文件**删除**;`macos-cookbook.md` 刷新保留;`native-feel/`、`design/`(→ `design-system/`)作为 domain 保留。`macbook/` 非 git 仓库,用普通 `mv`/`rm`。

## 3. 目标布局

```
macbook/
├── index.md                    # 总入口:区块树导航 + domain 模块 + 冲突裁决记录 + 各篇源码锚定版本
│
├── 〔区块树〕通用 macOS 原生开发知识(跨项目融合去重)
│   ├── project-layout/         # 模块/SPM 分层、依赖方向、增量构建隔离
│   ├── concurrency/            # Swift 6 严格并发、@MainActor、Sendable 边界、@unchecked 边界登记
│   ├── logging/                # ★CocoaLumberjack/LogService;OSLog 底层与适用边界;DEBUG-only 对比
│   ├── error-handling/         # 三层错误:域错误→跨域包装→跨进程序列化
│   ├── private-api/            # dlopen/dlsym 私有框架(MediaRemote、DisplayServices)
│   ├── window/                 # NSWindow/NSPanel、notch 面板、多屏 overlay、completion flash/glow、tri-state、窗口约定
│   ├── events-hotkeys/         # 全局事件监听、CGEvent 拟真输入、KeyboardShortcuts/Carbon 热键
│   ├── media/                  # MediaRemote、NowPlayingCLI daemon、ScriptingBridge reconcile
│   ├── system-sensing/         # CPU/内存/磁盘采样、亮度、电量
│   ├── accessibility/          # AX 树遍历 + Focus、Dock 角标
│   ├── screen-capture/         # ScreenCaptureKit、窗口枚举、Spaces
│   ├── permissions/            # TCC 状态机、PermissionCard never-auto-prompt、GENERATE_INFOPLIST_FILE 陷阱
│   ├── ipc/                    # Unix socket、subprocess、HookServer + hook installer(写 settings.json)
│   ├── keychain/               # Keychain 基础、cdhash-gated 静默读、accessibility 常量
│   ├── swiftui/                # SwiftUI 模式、AppKit 桥接、Liquid Glass、状态驱动紧凑 UI/badge 状态机、原生约定、样式 token
│   ├── architecture/           # @Observable 服务层、DI、状态所有权、单一真相源 store、protocol-first 多 Provider、持久化
│   ├── testing/                # 权限敏感测试 gating、Swift Testing
│   └── build-release/          # 签名/公证/DMG、应用数据路径、Poltergeist 增量构建、UI-test 截图 harness
│
├── 〔domain 模块〕非系统区块,保留独立主题
│   ├── ai-codegen/             # Ironsmith AI 代码生成管线(prompt 工程、输出清洗、编译诊断解析、修复循环、回滚安全)
│   ├── native-feel/            # Raycast WebView 跨平台 skill(技术栈不同,基本不动;index 标注适用场景)
│   └── design-system/          # NemoNotch Warm Noir 视觉系统(原 design/)
│
└── macos-cookbook.md           # 【刷新】NemoNotch 专属 file:line 速查;区块树引用它取精确锚点
```

**职责分离**:区块树 = 跨项目**泛化**知识;cookbook = NemoNotch **专属精确锚点**;domain = 不属系统区块的领域主题。三者交叉链接,不重复正文。

## 4. 区块 ← 来源映射(实施依据)

> 缩写:P=Peekaboo `macos/`,N=NemoNotch `macos-cookbook.md`,I=Ironsmith `principles`,R=Raycast `native-feel/`,D=`design/`。

| 区块 | 来源 |
|---|---|
| `project-layout/` | P01;I-2/16;N §3(构建部分) |
| `concurrency/` | P02;N §15;I-4 |
| `logging/` | **N §18(主)**;P03(OSLog 底层);I(DEBUG 诊断对比) |
| `error-handling/` | P04 |
| `private-api/` | N §4 |
| `window/` | N §5;P09(窗口部分)/P10(overlay);R(windowing 约定) |
| `events-hotkeys/` | N §6;P07 |
| `media/` | N §7、§9 |
| `system-sensing/` | N §8 |
| `accessibility/` | N §10;P06 |
| `screen-capture/` | P08 |
| `permissions/` | N §11;P05;N §2/§3(Info.plist 陷阱) |
| `ipc/` | N §12、§13 |
| `keychain/` | N §14;I-7 |
| `swiftui/` | N §16;P09;I-20;D(样式 token);R(native-conventions) |
| `architecture/` | N §17;I-2/3/4/5/8;NemoNotch store/registry/protocol-first |
| `testing/` | P12;N(测试约定);I-21 |
| `build-release/` | N §3、§20(uitest);P11;I-16/17/18/19 |
| `ai-codegen/`(domain) | I-9~15 |
| `native-feel/`(domain) | R 全套(保留) |
| `design-system/`(domain) | D 全套(保留) |

**删除**(完全并入后):`macos/` 整个文件夹、`ai-swift-app-development-principles.md`。
**保留**:`macos-cookbook.md`(刷新)、`native-feel/`、`design/`→`design-system/`。

## 5. 单篇与索引规范

**区块 = 文件夹**;内部按**子主题**分 md(如 `window/notch-panel.md`、`window/multi-screen-overlay.md`、`window/window-conventions.md`)。小区块可单文件。每个区块文件夹含一个 `index.md` 简述 + 列出本区块子主题。

**单篇骨架**(沿用 Peekaboo 体例):
```
frontmatter: summary / read_when / sources(融合自哪些来源)/ last_verified(各源锚点)
→ TL;DR
→ 泛化的可复用模式
→ 真实 file:line 锚点(指向源项目或 NemoNotch 代码 / cookbook)
→ Pitfalls
→ 落地 checklist
→ 延伸阅读(双向链接其它区块 / domain)
```

**根 `index.md`**:总入口。分三块导航 —— 区块树(按"基础设施 / 系统集成 / 视觉交互 / 工程实践"分组)、domain 模块、**冲突裁决记录表**(记录每条硬冲突最终怎么定的,可追溯)。

**语言**:中文 + 英文术语,与现有文档一致。

## 6. 已知冲突清单(实施中逐条上报裁决)

来自重构前对全库的审阅。融合到对应区块时,逐条找用户确认;裁决结果记入根 index 的冲突表。

| 区块 | 冲突 | 预案 |
|---|---|---|
| logging | swift-log(P01)/ OSLog(P03)/ CocoaLumberjack(N)/ 自研(I) | **已定:CocoaLumberjack 为主**;顺手修 P01 的 swift-log 离群描述 |
| permissions | "三态"标题 vs 五态代码 vs 七态图(P05) | 统一为代码事实(几态待用户定) |
| testing | `-D` vs `-Xswiftc -D`(P11:223 不生效);env 门控失效(P12 `runAutomationInput` 读的 key 与 suite 实际读的 key 不一致) | 取正确写法并标注;**真 bug,需用户确认修法** |
| keychain | accessibility 常量 `ThisDeviceOnly`(I)vs 示例未设(N) | 推荐 `ThisDeviceOnly`,标注 N 示例待补 |
| concurrency/DI/持久化 | SwiftData+闭包client+不用protocol(I)vs UserDefaults/JSON+protocol-first(N) | **项目差异非错误**:并列"两种选型 + 适用场景",不强裁 |
| window/swiftui | overlay level `.screenSaver`(P10)vs `.floating`(P09);system-accent(R)vs 固定橙色品牌色(D);OS 画窗体阴影(R)vs 自绘 notch 阴影(N) | **场景差异**:标注适用条件,不强裁 |
| screen-capture | `SCScreenshotManager` 版本门槛 12.3+ vs 14+(P08 自相矛盾) | 取 14+(正确),标注 |
| native-feel(domain 内修) | 审计项 30 vs 75;内存地板 150MB vs 90/130MB;"70+"实际约 60;冷/温启动数字不一 | 在 domain 内统一为文件实际值 |

## 7. 实施顺序(供 writing-plans 展开)

1. **建骨架**:创建区块树文件夹 + 各区块 `index.md` 占位 + 根 `index.md` 框架。
2. **刷新 cookbook**:用 `NemoNotch/docs/macos-cookbook.md`(2741 行 live 版)同步 `macbook/macos-cookbook.md`,补 §20。
3. **迁 domain**:`design/`→`design-system/`;从 `principles` 抽 9–15 章成 `ai-codegen/`;`native-feel/` 保留。
4. **逐区块融合**:按 §4 映射,每区块汇入多来源、去重、写成统一篇;命中 §6 冲突时上报。
5. **抽 domain 可复用经验进区块**:native-feel 原生约定 → swiftui/window;design-system 样式 → swiftui。
6. **删除原文件**:`mv`/`rm` 掉 `macos/`、`ai-swift-app-development-principles.md`(确认内容已全部并入后)。
7. **建交叉链接 + 冲突裁决表**:补全双向"延伸阅读",根 index 汇总裁决记录。
8. **校验**:无死链;每区块至少一个 `file:line` 锚点;删除项内容确已迁移;`read_when` 可定位。

## 8. 成功标准

- 任一 macOS 系统能力 → 能在区块树一个文件夹内定位到统一结论。
- §6 每条冲突在根 index 冲突表中有明确裁决记录。
- 原 `macos/` 与 `principles` 内容无丢失地分布到区块树 / domain;原文件已删。
- cookbook 刷新到 live 版且 TOC 与正文一致(含 §20)。
- 全库无指向已删文件的死链。
