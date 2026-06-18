# macbook 知识库按 macOS 区块全量重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 `../macbook/`(NemoNotch repo 之外的同级目录)从"按项目分散"的知识库重构成"按 macOS 开发区块组织"的统一树,融合 Peekaboo / NemoNotch / Ironsmith / Raycast 四来源,去重并裁决冲突。

**Architecture:** 18 个 macOS 区块文件夹 + 3 个 domain 模块 + 刷新版 cookbook + 根 index。每个区块是跨项目去重融合后的统一篇;cookbook 保留 NemoNotch 专属 `file:line` 精确锚点;domain 保留不属系统区块的领域主题。完全并入区块树的 `macos/` 与 `principles` 在内容迁移确认后删除。

**Tech Stack:** 纯 Markdown 文档;`git`(本地)做版本控制与逐任务提交;`grep`/`rg` 做迁移与死链校验。无代码、无编译、无单元测试 —— 每个任务的"测试周期"是**校验命令**(文件/章节存在性、锚点、死链、内容迁移)。

## Global Constraints

> 以下约束**隐含于每一个任务**,逐条 verbatim 来自设计文档 `docs/plans/2026-06-18-macbook-region-refactor-design.md`。

- **工作目录**:所有产物在 `../macbook/`(相对 NemoNotch repo)。设计/计划文档留在 NemoNotch `docs/plans/`。
- **语言**:中文正文 + 英文术语,与现有文档一致。
- **每区块合并成一篇视角**:同一区块多项目内容**融合去重**;**禁止**按项目分子文件(不要 `permissions/peekaboo.md` + `permissions/nemonotch.md`)。区块内可按**子主题**分多个 md。
- **硬冲突必须上报**:命中 §6 冲突清单时,**停下来向用户呈现选项并等待裁决**,不擅自取舍;裁决结果记入根 `index.md` 冲突表。
- **logging 主线 = CocoaLumberjack**(NemoNotch `LogService` = `DDOSLogger` + `DDFileLogger`);OSLog 讲底层与适用边界。
- **删除前必须先确认内容已迁移**:删 `macos/`、`ai-swift-app-development-principles.md` 前,逐篇核对内容已进区块树/domain。
- **源缩写**:P=Peekaboo `macos/`,N=NemoNotch `macos-cookbook.md`,I=Ironsmith `ai-swift-app-development-principles.md`,R=Raycast `native-feel/`,D=`design/`。
- **NemoNotch live cookbook 源**:`/Users/gaozimeng/Learn/macOS/NemoNotch/docs/macos-cookbook.md`(2741 行,刷新基准)。

## Conventions(每个区块篇都遵循 — 视为每个迁移任务的一部分)

**单篇 frontmatter 模板**(逐字段填实,不留空):
```markdown
---
summary: '<一句话:本篇覆盖的 macOS 能力>'
read_when:
  - '<什么时候该读这篇>'
sources: ['<P0X / N §Y / I-Z / R / D 中本篇融合自哪些>']
last_verified:
  peekaboo: '<短 SHA 或 n/a>'
  nemonotch: 'fe4e9e5'
---
```

**单篇骨架**(章节顺序固定):
```
# <标题>
## TL;DR
## 可复用模式（泛化,不绑单一项目）
## 锚点（file:line，指向源项目代码 / NemoNotch 代码 / cookbook 章节）
## Pitfalls
## 落地 checklist
## 延伸阅读（双向链接其它区块 / domain,用相对路径)
```

**每个区块文件夹**含一个 `index.md`:3–5 行"本区块是什么" + 列出本文件夹各子主题 md(相对链接)。

**单任务校验命令模板**(按区块替换路径):
```bash
cd ../macbook
# 1. 产物存在且非空
test -s <region>/index.md && for f in <region>/*.md; do test -s "$f" || echo "EMPTY: $f"; done
# 2. 至少一个 file:line 锚点(形如 `xxx.swift:123` 或 `:行号`)
grep -rEq '\.(swift|pl|sh|json):[0-9]+|:[0-9]+\b' <region>/ || echo "NO ANCHOR in <region>/"
# 3. 无指向已删源(macos/ 或 principles)的死链
grep -rn 'macos/0[1-9]\|ai-swift-app-development-principles' <region>/ && echo "DEAD LINK in <region>/" || true
```

**单任务提交模板**:
```bash
cd ../macbook && git add <paths> && git commit -m "<msg>"
```

---

## Phase 0 — 安全与骨架

### Task 1: macbook 版本化 + 区块树骨架

**Files:**
- Create: `../macbook/.git/`(via `git init`)、`../macbook/.gitignore`(忽略 `.DS_Store`)
- Create: 18 个区块文件夹 + 3 个 domain 占位 + 根 `index.md`

**Interfaces:**
- Produces: 完整空骨架目录树(后续任务往里填),根 `index.md` 框架(含"冲突裁决表"空表)。

- [ ] **Step 1: 初始化 git + 基线提交(保留可回溯起点)**

```bash
cd ../macbook
git init -q
printf '.DS_Store\n' > .gitignore
git add -A && git commit -q -m "chore: baseline before macOS-region refactor"
```

- [ ] **Step 2: 建区块树与 domain 文件夹**

```bash
cd ../macbook
for d in project-layout concurrency logging error-handling private-api window \
         events-hotkeys media system-sensing accessibility screen-capture \
         permissions ipc keychain swiftui architecture testing build-release; do
  mkdir -p "$d"
done
mkdir -p ai-codegen design-system   # native-feel 已存在,保留
```

- [ ] **Step 3: 写根 index.md 框架**

写 `../macbook/index.md`,包含三段:① 区块树导航(按"基础设施 / 系统集成 / 视觉交互 / 工程实践"分组列出 18 区块,先放占位链接);② domain 模块(`ai-codegen/`、`native-feel/`、`design-system/`、`macos-cookbook.md`);③ 一张空的"冲突裁决记录表"(列:区块 | 冲突 | 裁决 | 日期)。

- [ ] **Step 4: 校验骨架**

```bash
cd ../macbook && ls -d */ && test -s index.md && echo OK
```
Expected: 列出 21 个文件夹(18 区块 + ai-codegen + design-system + native-feel),`index.md` 非空,打印 `OK`。

- [ ] **Step 5: 提交**

```bash
cd ../macbook && git add -A && git commit -q -m "scaffold: macOS region tree + domain folders + root index"
```

---

### Task 2: 刷新 cookbook 到 live 版

**Files:**
- Modify: `../macbook/macos-cookbook.md`(2501 → 2741 行)
- Source: `/Users/gaozimeng/Learn/macOS/NemoNotch/docs/macos-cookbook.md`

**Interfaces:**
- Produces: 刷新后的 cookbook,TOC 与正文一致(含 §20 UI-test 截图 harness)。区块树后续引用它取精确锚点。

- [ ] **Step 1: 用 live 版整体替换**

```bash
cp /Users/gaozimeng/Learn/macOS/NemoNotch/docs/macos-cookbook.md ../macbook/macos-cookbook.md
```

- [ ] **Step 2: 校验 §20 与 TOC 一致**

```bash
cd ../macbook
grep -n '^20\.' macos-cookbook.md && grep -n 'uitest\|UI-test\|--uitest' macos-cookbook.md | head -3
```
Expected: TOC 含第 20 条且正文存在 §20(`--uitest`)章节。

- [ ] **Step 3: 提交**

```bash
cd ../macbook && git add macos-cookbook.md && git commit -q -m "docs: refresh cookbook to NemoNotch live (2741 lines, +§20)"
```

---

## Phase 1 — Domain 模块(独立、低冲突)

### Task 3: design/ → design-system/

**Files:**
- Move: `../macbook/design/*` → `../macbook/design-system/`
- Modify: `design-system/index.md`(更新内部相对链接)

**Interfaces:**
- Produces: `design-system/`(warm-noir-utility.md / ai-ui-prompt.md / ui-review-checklist.md / index.md)。可复用样式经验在 Task 18(swiftui)抽取,本任务只搬迁。

- [ ] **Step 1: 搬迁**

```bash
cd ../macbook && git mv design/warm-noir-utility.md design/ai-ui-prompt.md design/ui-review-checklist.md design/index.md design-system/ && rmdir design 2>/dev/null || true
```

- [ ] **Step 2: 修 index 内链 + 标注 domain 性质**

编辑 `design-system/index.md`:确认指向同目录三篇的相对链接仍有效;在顶部加一行说明"本模块为 NemoNotch 专属视觉身份(单 OS 原生 SwiftUI),其可复用样式约定见 `../swiftui/`"。

- [ ] **Step 3: 校验无死链**

```bash
cd ../macbook && grep -rn '](\./' design-system/ | grep -v 'warm-noir\|ai-ui-prompt\|ui-review' && echo "CHECK LINKS" || echo OK
```
Expected: `OK`(或仅列出已确认有效的链接)。

- [ ] **Step 4: 提交**

```bash
cd ../macbook && git add -A && git commit -q -m "domain: move design/ → design-system/"
```

---

### Task 4: 从 principles 抽出 ai-codegen/ domain

**Files:**
- Create: `../macbook/ai-codegen/index.md`、`ai-codegen/pipeline.md`、`ai-codegen/prompt-engineering.md`、`ai-codegen/output-sanitize-and-fix.md`
- Source: `ai-swift-app-development-principles.md` 第 9–15 章(AI 生成管线总览 / Prompt 工程 / 输出清洗 / 编译诊断解析 / 确定性修复器 / 模型 diff 修复 / 修复循环编排)

**Interfaces:**
- Produces: `ai-codegen/` domain。**注意**:principles 第 1–8、16–23 章是 macOS 原生通用知识,**不在本任务**,留给后续区块任务(Task 19/20/24 等)抽取后再删 principles。

- [ ] **Step 1: 切分章节到 ai-codegen 子文件**

读 `ai-swift-app-development-principles.md` 第 9–15 章。按子主题写出:
- `ai-codegen/pipeline.md` ← 第 9 章(管线总览)+ 第 15 章(修复循环编排与回滚安全)
- `ai-codegen/prompt-engineering.md` ← 第 10 章(Prompt 工程原则)
- `ai-codegen/output-sanitize-and-fix.md` ← 第 11–14 章(输出清洗 / 编译诊断解析 / 确定性修复器 / 模型 diff 修复)

每篇套用 Conventions frontmatter + 骨架;`sources` 标 `I-9~15`;锚点保留原文 `文件:行号`。

- [ ] **Step 2: 写 ai-codegen/index.md**

3–5 行说明 + 列三篇 + 一行"本模块是 AI 代码生成业务领域,非 macOS 系统区块;可复用的签名/路径/SwiftPM 细节见区块树"。

- [ ] **Step 3: 校验**

```bash
cd ../macbook && for f in ai-codegen/pipeline.md ai-codegen/prompt-engineering.md ai-codegen/output-sanitize-and-fix.md ai-codegen/index.md; do test -s "$f" || echo "EMPTY $f"; done; echo done
```
Expected: 仅打印 `done`(无 EMPTY)。

- [ ] **Step 4: 提交**

```bash
cd ../macbook && git add ai-codegen && git commit -q -m "domain: extract ai-codegen/ from principles ch.9-15"
```

---

### Task 5: native-feel/ 保留 + 标注适用场景 + 修自身数字

**Files:**
- Modify: `native-feel/SKILL.md`、`native-feel/README.md`、`native-feel/references/06-native-conventions.md`、`native-feel/references/02-architecture.md`、`native-feel/checklists/decision-tree.md`

**Interfaces:**
- Produces: native-feel domain 内部数字自洽。可复用的"原生约定"在 Task 17/18 抽进 window/swiftui。

- [ ] **Step 1: 修审计项数 30→75**

`native-feel/SKILL.md:21`:把 "30-item audit" 改为 "75-item audit"(文件实际 75 项,README 已正确)。

- [ ] **Step 2: 统一冷/温启动与内存数字**

以 `references/02-architecture.md` 与 `references/05-memory-truths.md` 的**详细值为准**,修正 README/decision-tree/SKILL 中的概述值:
- 冷启动 rule-out 阈值统一为文件主张的一致值(architecture 用 <50ms,README/decision-tree 用 <100ms — 取其一并三处统一,**此为 native-feel 内部数字,非 §6 跨项目冲突,执行者按"以详细 evidence 文件为准"自行统一**)。
- 内存地板:README/SKILL/decision-tree 的 "150MB" 改为与 `05-memory-truths.md` 一致的 "macOS ~90MB / Windows ~130MB"。
- `06-native-conventions.md` 的 "70+ 项" 概述改为与实际条目数一致。

- [ ] **Step 3: 校验数字一致**

```bash
cd ../macbook && grep -rn '30-item\|75-item' native-feel/ && grep -rn '150 ?MB\|90 ?MB\|130 ?MB' native-feel/
```
Expected: 只剩 "75-item";内存数字三处指向 90/130 而非 150。

- [ ] **Step 4: 提交**

```bash
cd ../macbook && git add native-feel && git commit -q -m "domain: fix native-feel internal number inconsistencies (30→75, memory floor)"
```

---

## Phase 2 — 区块树:低冲突区块(纯迁移融合)

> 以下每个任务:读 §4 映射的源 → 按 Conventions 骨架写区块篇 → 校验 → 提交。无 §6 硬冲突,执行者直接融合去重。

### Task 6: project-layout/

**Files:** Create `project-layout/index.md`、`project-layout/module-and-spm-layout.md`、`project-layout/build-isolation.md`
**Sources:** P01(模块分层/依赖方向);I 第 2、16 章(顶层架构/SwiftPM 包生成);N §3(构建配置部分)

- [ ] **Step 1: 写 module-and-spm-layout.md** ← P01 的单向层次模块 + SPM 编译隔离 + I-2 分层;融合"把增量构建从 43s 压到 5s"的实践。**注意 P01 用 apple/swift-log 作脚手架依赖 → 日志相关一行改为指向 `../logging/`,不在本篇展开后端选型**(logging 区块统一)。
- [ ] **Step 2: 写 build-isolation.md** ← 增量构建隔离 + I-16 包生成与构建。
- [ ] **Step 3: 写 index.md**(本区块导航)。
- [ ] **Step 4: 校验**(套用 Conventions 校验模板,`<region>`=project-layout)。
- [ ] **Step 5: 提交** `region(project-layout): module/SPM layout + build isolation`

### Task 7: error-handling/

**Files:** Create `error-handling/index.md`、`error-handling/three-layer-errors.md`
**Sources:** P04(三层架构:域错误→跨域包装→跨进程序列化,用户消息与诊断 payload 分离)

- [ ] **Step 1: 写 three-layer-errors.md** ← P04 全篇泛化,保留 `logged()` 桥接等锚点;日志桥接处链接 `../logging/`。
- [ ] **Step 2: 写 index.md**。
- [ ] **Step 3: 校验**(`<region>`=error-handling)。
- [ ] **Step 4: 提交** `region(error-handling): three-layer error model`

### Task 8: private-api/

**Files:** Create `private-api/index.md`、`private-api/dlopen-dlsym-loading.md`
**Sources:** N §4(私有 API 加载:MediaRemote、DisplayServices 的 dlopen/dlsym 模式)

- [ ] **Step 1: 写 dlopen-dlsym-loading.md** ← N §4 泛化模式 + cookbook `file:line` 锚点。
- [ ] **Step 2: 写 index.md**。
- [ ] **Step 3: 校验**(`<region>`=private-api)。
- [ ] **Step 4: 提交** `region(private-api): dlopen/dlsym private framework loading`

### Task 9: media/

**Files:** Create `media/index.md`、`media/mediaremote-and-nowplaying.md`、`media/scriptingbridge-reconcile.md`
**Sources:** N §7(Media:MediaRemote + NowPlayingCLI daemon)、N §9(ScriptingBridge & AppleScript + reconcile 机制)

- [ ] **Step 1: 写 mediaremote-and-nowplaying.md** ← N §7;含 NowPlayingCLI daemon、dylib 提取路径、play/pause reconcile 流程。
- [ ] **Step 2: 写 scriptingbridge-reconcile.md** ← N §9;含 setPlayerPosition seek、乐观 UI + 权威态 reconcile。
- [ ] **Step 3: 写 index.md**。
- [ ] **Step 4: 校验**(`<region>`=media)。
- [ ] **Step 5: 提交** `region(media): MediaRemote/NowPlayingCLI + ScriptingBridge reconcile`

### Task 10: system-sensing/

**Files:** Create `system-sensing/index.md`、`system-sensing/cpu-memory-disk.md`、`system-sensing/brightness-battery.md`
**Sources:** N §8(系统采样:host_processor_info / host_statistics64 / 亮度 DisplayServices / 电量)

- [ ] **Step 1: 写 cpu-memory-disk.md** ← N §8 采样部分。
- [ ] **Step 2: 写 brightness-battery.md** ← N §8 亮度/电量(链接 `../private-api/` 取 dlopen 模式)。
- [ ] **Step 3: 写 index.md**。
- [ ] **Step 4: 校验**(`<region>`=system-sensing)。
- [ ] **Step 5: 提交** `region(system-sensing): CPU/mem/disk + brightness/battery`

### Task 11: accessibility/

**Files:** Create `accessibility/index.md`、`accessibility/ax-tree-and-focus.md`、`accessibility/dock-badges.md`
**Sources:** P06(AXorcist 元素查找 + Focus,操作前重新 query 防 stale);N §10(AX & Dock 角标)

- [ ] **Step 1: 写 ax-tree-and-focus.md** ← P06 类型安全 AX 遍历 + N §10;强调 stale 引用陷阱。
- [ ] **Step 2: 写 dock-badges.md** ← N §10 Dock 角标(Accessibility API)。
- [ ] **Step 3: 写 index.md**。
- [ ] **Step 4: 校验**(`<region>`=accessibility)。
- [ ] **Step 5: 提交** `region(accessibility): AX tree/Focus + Dock badges`

### Task 12: screen-capture/

**Files:** Create `screen-capture/index.md`、`screen-capture/screencapturekit-and-fallback.md`、`screen-capture/windows-and-spaces.md`
**Sources:** P08(ScreenCaptureKit 优先,旧版回退 CGWindowList,Spaces 走 CGS 私有 API)

- [ ] **Step 1: 写 screencapturekit-and-fallback.md** ← P08。**修 P08 自相矛盾**:`SCScreenshotManager`(单帧)统一标 **macOS 14+**(P08:829 正确),而非 12.3+(P08:12 错误);`SCShareableContent.current` 标 12.3+。此为 P 内部错误,直接取正确值并在 Pitfalls 注明。
- [ ] **Step 2: 写 windows-and-spaces.md** ← P08 窗口枚举 + Spaces CGS。
- [ ] **Step 3: 写 index.md**。
- [ ] **Step 4: 校验**(`<region>`=screen-capture)。
- [ ] **Step 5: 提交** `region(screen-capture): ScreenCaptureKit + windows/Spaces (fix version floor)`

### Task 13: events-hotkeys/

**Files:** Create `events-hotkeys/index.md`、`events-hotkeys/global-event-monitor.md`、`events-hotkeys/cgevent-input-synthesis.md`、`events-hotkeys/hotkeys.md`
**Sources:** N §6(事件捕获 & 热键);P07(CGEvent 拟真输入)

- [ ] **Step 1: 写 global-event-monitor.md** ← N §6 鼠标进出/全局监听。
- [ ] **Step 2: 写 cgevent-input-synthesis.md** ← P07;**修 P07 内部不一致**:对数正态下限钳制统一取一个值(P07:93 用 0.2×、:104 用 0.25×),执行者取 P 实测代码值 **0.2×** 并在文中统一,Pitfalls 注明曾有 0.25× 表述。
- [ ] **Step 3: 写 hotkeys.md** ← N §6 热键(KeyboardShortcuts / Carbon)。
- [ ] **Step 4: 写 index.md**。
- [ ] **Step 5: 校验**(`<region>`=events-hotkeys)。
- [ ] **Step 6: 提交** `region(events-hotkeys): event monitor + CGEvent synth + hotkeys`

### Task 14: ipc/

**Files:** Create `ipc/index.md`、`ipc/unix-socket-and-subprocess.md`、`ipc/hook-server.md`、`ipc/hook-installer.md`、`ipc/incremental-parsing.md`
**Sources:** N §12(IPC & subprocess)、N §13(Hook installers)

- [ ] **Step 1: 写 unix-socket-and-subprocess.md** ← N §12 基础 IPC/子进程。
- [ ] **Step 2: 写 hook-server.md** ← N §12 HookServer Unix socket、hook 事件协议、进程树检测。
- [ ] **Step 3: 写 hook-installer.md** ← N §13 写 `~/.claude/settings.json`、幂等装卸、备份。
- [ ] **Step 4: 写 incremental-parsing.md** ← 增量 JSONL/JSON 会话解析、InterruptWatcher、AgentFileWatcher(cookbook 相关章节)。
- [ ] **Step 5: 写 index.md**。
- [ ] **Step 6: 校验**(`<region>`=ipc)。
- [ ] **Step 7: 提交** `region(ipc): unix socket/subprocess + hook server/installer + incremental parsing`

---

## Phase 3 — 区块树:冲突区块(需用户裁决检查点)

> 以下任务命中 §6 冲突。每个含一个 **STOP 步骤**:呈现选项、等用户裁决、把结果写进根 index 冲突表后再继续。

### Task 15: logging/(冲突:logger 选型 — 已定 CocoaLumberjack)

**Files:** Create `logging/index.md`、`logging/cocoalumberjack-logservice.md`、`logging/oslog-foundation.md`
**Sources:** N §18(主);P03(OSLog);I(DEBUG 诊断对比)

- [ ] **Step 1: 写 cocoalumberjack-logservice.md** ← N §18 为主线:`DDOSLogger` + `DDFileLogger`、`~/.NemoNotch/logs/` 日轮转 7 份、`nonisolated` 静态 API、release `.info` 级别。**修 N §18.2 事实错挂**:`nonisolated(unsafe) static let shared` 是单例(cookbook:2138),静态 `debug/info/warn/error` 直接调 `DDLogDebug` 不经 `shared` —— 文中分清两者。
- [ ] **Step 2: 写 oslog-foundation.md** ← P03 的 OSLog/`subsystem`/`category`/`log stream` 作为**底层与"何时纯 OSLog 就够"**;说明 CocoaLumberjack 在其上叠 `DDOSLogger`;对比 I 的 DEBUG-only 自研诊断。**修 P01 离群描述**:在本篇 Pitfalls 注明"P01 脚手架曾用 apple/swift-log,本树统一以 CocoaLumberjack(应用)/OSLog(底层)为准"。
- [ ] **Step 3: 写 index.md** + 在根 index 冲突表记一行:`logging | swift-log/OSLog/CocoaLumberjack/自研 | 选 CocoaLumberjack 为主、OSLog 底层 | 2026-06-18`。
- [ ] **Step 4: 校验**(`<region>`=logging)。
- [ ] **Step 5: 提交** `region(logging): CocoaLumberjack primary + OSLog foundation`

### Task 16: permissions/(冲突:状态机几态 — 需裁决)

**Files:** Create `permissions/index.md`、`permissions/tcc-state-machine.md`、`permissions/permission-card-ux.md`、`permissions/infoplist-pitfall.md`
**Sources:** P05(TCC 三/五/七态);N §11(权限 playbook);N §2/§3(GENERATE_INFOPLIST_FILE 陷阱)

- [ ] **Step 1: STOP — 向用户呈现状态机命名冲突**

呈现:P05 标题"三态",代码枚举**五态**(`unknown/prompted/granted/denied/revoked`,P05:245),ASCII 图**七态**(额外 `in_effect`/`denied_sticky`,P05:44)。问用户:本篇统一叫几态、用哪套枚举?等裁决。
- [ ] **Step 2: 写 tcc-state-machine.md** ← 按用户裁决的态数/枚举;融合 N §11 三类 TCC 权限(Screen Recording/Accessibility/AppleEvents)生效时机差异与轮询。
- [ ] **Step 3: 写 permission-card-ux.md** ← N "never auto-prompt" + PermissionCard"Grant"按钮模式(Calendar/Location/Automation/Notification/AX)。
- [ ] **Step 4: 写 infoplist-pitfall.md** ← N §2/§3:`GENERATE_INFOPLIST_FILE=YES` → 必须用 `INFOPLIST_KEY_*`;缺 `NSAppleEventsUsageDescription` 导致自动化授权对话框静默不弹;PlistBuddy 验证步骤。
- [ ] **Step 5: 写 index.md** + 根 index 冲突表记裁决。
- [ ] **Step 6: 校验**(`<region>`=permissions)。
- [ ] **Step 7: 提交** `region(permissions): TCC state machine + PermissionCard + Info.plist pitfall`

### Task 17: window/(冲突:overlay level / 窗口约定 场景差异 — 并列不强裁)

**Files:** Create `window/index.md`、`window/nspanel-and-notch.md`、`window/multi-screen-overlay.md`、`window/window-conventions.md`
**Sources:** N §5(Notch & window);P09(窗口部分)/P10(overlay);R(windowing 约定,可复用经验抽取)

- [ ] **Step 1: 写 nspanel-and-notch.md** ← N §5:NSPanel `.statusBar+8`、`fullScreenAuxiliary`+`stationary`+`canJoinAllSpaces`、tri-state、hotkey-aware dismiss、completion flash/glow ring 的 `.mask`/`.screen` 技法。
- [ ] **Step 2: 写 multi-screen-overlay.md** ← P10 + N:per-screen WindowController、`didChangeScreenParameters` 重建、"看得见点不到不抢焦点"。**STOP — 呈现 overlay level 冲突**:P10 用 `.screenSaver`、P09 用 `.floating`。这是**场景差异**(通用 overlay vs 跟随外部窗口),预案是**并列两种 + 标注适用条件**;向用户确认认可此处理(而非二选一)。
- [ ] **Step 3: 写 window-conventions.md** ← 从 R(native-feel)抽可复用的窗口原生约定(OS 画阴影/圆角等),**标注**:R 假设标准 titled 窗口;NemoNotch 的无边框 notch 面板必须自绘形状/阴影 —— 两者适用场景不同,不强裁。
- [ ] **Step 4: 写 index.md** + 根 index 冲突表记一行(overlay level:并列处理)。
- [ ] **Step 5: 校验**(`<region>`=window)。
- [ ] **Step 6: 提交** `region(window): NSPanel/notch + multi-screen overlay + window conventions`

### Task 18: swiftui/(冲突:accent/spring/toast 场景差异 — 并列不强裁)

**Files:** Create `swiftui/index.md`、`swiftui/swiftui-patterns.md`、`swiftui/appkit-bridging-liquid-glass.md`、`swiftui/state-driven-compact-ui.md`、`swiftui/native-conventions.md`
**Sources:** N §16;P09;I 第 20 章;D(样式 token,可复用抽取);R(native-conventions,可复用抽取)

- [ ] **Step 1: 写 swiftui-patterns.md** ← N §16 + I-20 SwiftUI 模式。
- [ ] **Step 2: 写 appkit-bridging-liquid-glass.md** ← P09 `@main App` + `@NSApplicationDelegateAdaptor` 混合 + Liquid Glass 适配器。
- [ ] **Step 3: 写 state-driven-compact-ui.md** ← NemoNotch badge 优先级纯函数状态机、`glow(for:)` 决策、collapsed/expanded 契约。
- [ ] **Step 4: 写 native-conventions.md** ← 从 R + D 抽可复用样式/交互约定。**STOP — 呈现三处场景差异**:① accent:R 主张跟随系统强调色 vs D 固定橙色品牌色;② 动画:R "简单状态变化不用 spring" vs N 开合/tab 用 spring;③ toast:R "不用 web 式 toast" vs N 的 HUD toast。预案:**三条都标"适用场景不同,非错误"并列说明**;向用户确认认可此处理。
- [ ] **Step 5: 写 index.md** + 根 index 冲突表记三行(accent/spring/toast:场景差异并列)。
- [ ] **Step 6: 校验**(`<region>`=swiftui)。
- [ ] **Step 7: 提交** `region(swiftui): patterns + AppKit/Liquid Glass + state-driven UI + native conventions`

### Task 19: architecture/(冲突:DI/持久化 项目差异 — 并列不强裁)

**Files:** Create `architecture/index.md`、`architecture/observable-service-layer.md`、`architecture/state-ownership-and-di.md`、`architecture/single-source-store.md`、`architecture/protocol-first-providers.md`、`architecture/persistence.md`
**Sources:** N §17;I 第 2/3/4/5/8 章;NemoNotch store/registry/protocol-first

- [ ] **Step 1: 写 observable-service-layer.md** ← N §17:Service→@Observable→SwiftUI 重绘、AppDelegate 装配/所有权、`@Environment` 注入、LifecycleAware、刷新节流。
- [ ] **Step 2: 写 state-ownership-and-di.md** ← I-3/4/5 菜单栏外壳 + 状态所有权 + 闭包式 client DI。**STOP — 呈现 DI 哲学冲突**:I "不用 protocol/mock 仪式、用闭包 client" vs N protocol-first。预案:**并列"两种 DI 选型 + 适用场景"**,不强裁;向用户确认。
- [ ] **Step 3: 写 single-source-store.md** ← NemoNotch AISessionStore:中心 store(upsert/mutate/mutateOrCreate)、provider 只写、UI 只读 sortedSessions。
- [ ] **Step 4: 写 protocol-first-providers.md** ← AIProvider / MultiAgentMonitor + Registry、独立 Result 类型不强行统一。
- [ ] **Step 5: 写 persistence.md** ← **STOP — 呈现持久化冲突**:I SwiftData `@Model`/`ModelContainer` vs N UserDefaults+JSON 文件。预案:**并列两种 + 按数据形态/规模选**;向用户确认。写成并列篇。
- [ ] **Step 6: 写 index.md** + 根 index 冲突表记两行(DI、持久化:项目差异并列)。
- [ ] **Step 7: 校验**(`<region>`=architecture)。
- [ ] **Step 8: 提交** `region(architecture): service layer + DI + store + protocol-first + persistence`

### Task 20: keychain/(冲突:accessibility 常量 — 推荐 ThisDeviceOnly)

**Files:** Create `keychain/index.md`、`keychain/keychain-basics.md`、`keychain/cdhash-gated-read.md`
**Sources:** N §14(Keychain + cdhash-gated 静默读);I 第 7 章(凭证与 Keychain)

- [ ] **Step 1: 写 keychain-basics.md** ← N §14 + I-7。**冲突处理(无需 STOP,预案明确)**:accessibility 常量统一**推荐 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`**(I-7 主张);在 Pitfalls 注明"N 的示例 `SecItemAdd` 未设 accessibility,生产应补"。service+account keying:多 secret 服务用 service+account(I),单 secret 可省 service(N)—— 并列说明。
- [ ] **Step 2: 写 cdhash-gated-read.md** ← N §14.3:attributes-only 探测(不弹窗)、cdhash gate、`SecKeychainSetUserInteractionAllowed(false)` 防自动刷新弹窗、UserDefaults 持久化 grant。
- [ ] **Step 3: 写 index.md** + 根 index 冲突表记一行(accessibility 常量:推荐 ThisDeviceOnly)。
- [ ] **Step 4: 校验**(`<region>`=keychain)。
- [ ] **Step 5: 提交** `region(keychain): basics (ThisDeviceOnly) + cdhash-gated silent read`

### Task 21: concurrency/(冲突:无硬冲突,项目一致)

**Files:** Create `concurrency/index.md`、`concurrency/swift6-strict-concurrency.md`
**Sources:** P02(Swift 6 严格并发,含 SILGen 崩溃规避);N §15;I-4

- [ ] **Step 1: 写 swift6-strict-concurrency.md** ← P02 + N §15:`@MainActor @Observable final class`、Sendable 边界、`@unchecked Sendable`/`nonisolated(unsafe)` 登记、SILGen 规避。P/N/I 此处一致,直接融合。
- [ ] **Step 2: 写 index.md**。
- [ ] **Step 3: 校验**(`<region>`=concurrency)。
- [ ] **Step 4: 提交** `region(concurrency): Swift 6 strict concurrency`

### Task 22: testing/(冲突:两个真 bug — 需裁决修法)

**Files:** Create `testing/index.md`、`testing/permission-gated-testing.md`、`testing/swift-testing.md`
**Sources:** P12(权限敏感测试 gating);N(测试约定);I 第 21 章

- [ ] **Step 1: STOP — 呈现两个真 bug 及修法**

呈现给用户:
① P11:223 用裸 `-DPEEKABOO_SKIP_AUTOMATION`,向 Swift 传 `#if` 标志须 `-Xswiftc -D`(P11:662 / P12:538 正确)→ 修法:统一 `-Xswiftc -D`。
② P12 env 门控失效:`runAutomationInput` 读 `PEEKABOO_RUN_INPUT_AUTOMATION_TESTS`,但实际 suite 用 `runAutomationActions` 读 `RUN_AUTOMATION_ACTIONS`,package.json 设的是前者 → input 测试永不启用。修法待用户定(统一 env key,选哪个)。
等用户确认两条修法。
- [ ] **Step 2: 写 permission-gated-testing.md** ← P12 四级分层(编译期标志 + 运行期 env),采用用户裁决的正确 `-Xswiftc -D` 写法与统一 env key;Pitfalls 注明原 P 的两个 bug。
- [ ] **Step 3: 写 swift-testing.md** ← Swift Testing(`import Testing`/`@Test`/`#expect`)+ I-21;测纯逻辑、跳过 AX/NSWindow 集成测试。
- [ ] **Step 4: 写 index.md** + 根 index 冲突表记两行(两 bug 修法)。
- [ ] **Step 5: 校验**(`<region>`=testing)。
- [ ] **Step 6: 提交** `region(testing): permission-gated gating (fix 2 bugs) + Swift Testing`

### Task 23: build-release/

**Files:** Create `build-release/index.md`、`build-release/signing-notarize-dmg.md`、`build-release/app-paths-and-data.md`、`build-release/poltergeist-incremental.md`、`build-release/uitest-screenshot-harness.md`
**Sources:** N §3、§20(uitest);P11(SwiftPM+Xcode+Poltergeist);I 第 16/17/18/19 章

- [ ] **Step 1: 写 signing-notarize-dmg.md** ← N §3 + I-17:签名/公证/DMG、`build.sh`/`ExportOptions.plist`、ad-hoc 签名与 cdhash 变化(链接 `../keychain/cdhash-gated-read.md`)。
- [ ] **Step 2: 写 app-paths-and-data.md** ← I-18 应用数据布局(`~/.appname/`)。
- [ ] **Step 3: 写 poltergeist-incremental.md** ← P11 混合工程进 `.xcworkspace` + Poltergeist 后台增量构建。
- [ ] **Step 4: 写 uitest-screenshot-harness.md** ← N §20(`--uitest` 截图 harness)。
- [ ] **Step 5: 写 index.md**。
- [ ] **Step 6: 校验**(`<region>`=build-release)。
- [ ] **Step 7: 提交** `region(build-release): signing/DMG + paths + Poltergeist + uitest harness`

---

## Phase 4 — 收尾:抽 domain 经验、删原文件、全局校验

### Task 24: 抽 native-feel/design-system 可复用经验进区块(交叉链接)

**Files:** Modify `swiftui/native-conventions.md`、`window/window-conventions.md`、`design-system/index.md`、`native-feel/SKILL.md`

**Interfaces:**
- Consumes: Task 17/18 已建的 `window/window-conventions.md`、`swiftui/native-conventions.md`。
- Produces: 区块 ↔ domain 双向链接;domain 内不重复正文,只在区块篇引用 + 在 domain index 反向指回。

- [ ] **Step 1: 双向链接**

在 `swiftui/native-conventions.md` / `window/window-conventions.md` 的"延伸阅读"加指向 `../native-feel/`、`../design-system/` 的相对链接;在 `native-feel/SKILL.md`、`design-system/index.md` 末尾加"可复用的原生约定/样式已抽进 `../swiftui/`、`../window/`"。

- [ ] **Step 2: 校验链接可达**

```bash
cd ../macbook && grep -rn 'native-feel\|design-system\|\.\./swiftui\|\.\./window' swiftui/native-conventions.md window/window-conventions.md native-feel/SKILL.md design-system/index.md
```
Expected: 双向链接均存在。

- [ ] **Step 3: 提交** `link: cross-reference domain reusable experience into regions`

### Task 25: 删除已迁移的原文件

**Files:** Delete `../macbook/macos/`(整个文件夹)、`../macbook/ai-swift-app-development-principles.md`

**Interfaces:**
- Consumes: Task 6–23 已把 P01–12 与 principles 全部章节迁入区块树/domain。

- [ ] **Step 1: 删除前核对内容已迁移**

```bash
cd ../macbook
# principles 第 9-15 章 → ai-codegen;其余章 → 各区块。逐项确认存在对应产物:
for p in project-layout/module-and-spm-layout.md concurrency/swift6-strict-concurrency.md \
         keychain/keychain-basics.md architecture/state-ownership-and-di.md \
         ai-codegen/pipeline.md testing/swift-testing.md build-release/signing-notarize-dmg.md; do
  test -s "$p" && echo "OK $p" || echo "MISSING $p — 不要删除,先补迁"
done
```
Expected: 全部 `OK`;若有 `MISSING` 停止,回到对应任务补迁。

- [ ] **Step 2: 删除**

```bash
cd ../macbook && rm -rf macos/ && rm -f ai-swift-app-development-principles.md
```

- [ ] **Step 3: 提交** `cleanup: remove migrated macos/ and principles (content moved to region tree + ai-codegen)`

### Task 26: 全局校验 + 根 index 定稿

**Files:** Modify `../macbook/index.md`(填实所有区块链接 + 冲突裁决表)

- [ ] **Step 1: 无死链(全库)**

```bash
cd ../macbook
grep -rn 'macos/0[1-9]\|macos/1[0-2]\|ai-swift-app-development-principles\|](\./design/' . --include='*.md' && echo "DEAD LINKS ↑" || echo "NO DEAD LINKS"
```
Expected: `NO DEAD LINKS`。

- [ ] **Step 2: 每区块至少一个 file:line 锚点**

```bash
cd ../macbook
for d in project-layout concurrency logging error-handling private-api window events-hotkeys media system-sensing accessibility screen-capture permissions ipc keychain swiftui architecture testing build-release; do
  grep -rEq '\.(swift|pl|sh|json):[0-9]+|:[0-9]+\b' "$d/" || echo "NO ANCHOR: $d"
done; echo "anchor check done"
```
Expected: 仅 `anchor check done`(无 NO ANCHOR)。

- [ ] **Step 3: 填实根 index**

补全 18 区块的真实相对链接(指向各区块 index.md);确认"冲突裁决记录表"含全部已裁决条目(logging / permissions / overlay level / accent-spring-toast / DI / 持久化 / keychain 常量 / testing 两 bug)。

- [ ] **Step 4: spec 覆盖核对**

对照设计文档 §4 映射表逐行确认:每个来源(P01–12、N §1–20、I 全章、R、D)都已落到区块树或 domain。打印一句"覆盖核对通过"。

- [ ] **Step 5: 提交** `finalize: root index links + conflict ledger + global link/anchor verification`

---

## Self-Review(已执行)

**1. Spec 覆盖**:设计 §3 布局 → Task 1 骨架;§4 映射每行 → Task 2–23(逐区块/ domain);§6 每条冲突 → 对应任务的 STOP 步骤(logging T15 / permissions T16 / overlay T17 / accent-spring-toast T18 / DI-持久化 T19 / keychain T20 / screen-capture T12 / events T13 / testing 两 bug T22 / native-feel 数字 T5);§7 实施顺序 → Phase 0–4;§8 成功标准 → Task 26 校验。无遗漏。

**2. 占位符扫描**:无 "TBD/TODO/稍后";所有"待用户裁决"项都包成显式 STOP 步骤(非占位,是设计要求的交互检查点)。

**3. 类型/命名一致**:区块文件夹名在 §3 布局、§4 映射、各 Task、Task 26 校验循环中**逐字一致**(18 个名:project-layout / concurrency / logging / error-handling / private-api / window / events-hotkeys / media / system-sensing / accessibility / screen-capture / permissions / ipc / keychain / swiftui / architecture / testing / build-release)。

**4. 删除安全**:Task 25 删除前有内容迁移核对;Task 1 已建 git 基线,可整体回滚。
