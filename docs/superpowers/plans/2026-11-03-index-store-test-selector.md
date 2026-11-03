# Index Store 版测试选择器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans(本仓恒选:主对话逐任务执行)。Steps use checkbox (`- [ ]`) syntax for tracking.
> **教训(2026-11-03 settingsview 实跑):plan checkbox 全部勾完再进评审——事后补勾=纯文档提交也欠一轮 Reviewed-Head 刷新。**

**Goal:** `affected-tests.sh` 的选择中段从文本符号匹配升级为编译器索引的传递引用闭包,文本匹配降级为回落路径。

**Architecture:** 单文件 Swift 脚本 `scripts/index-affected.swift` 经 dlopen 直连工具链 libIndexStore(C API 子集、`@convention(c)` 自声明,无 SPM/C target);一次全扫描建 `defs[file]→USRs` / `refs[usr]→files` 两张内存表,BFS 出受影响文件闭包。`affected-tests.sh` 按 `WorkspacePath` 全等定位本 worktree 的 DerivedData,调 CLI 拿闭包 ∩ 测试文件,任何不健康信号 exit 3 → 原文本路径原样回落。

**Tech Stack:** Swift(脚本模式,Foundation+Darwin)、libIndexStore.dylib C API(indexstore-db 公开头为签名参照)、POSIX sh。

**Spec:** `docs/superpowers/specs/2026-11-03-index-store-test-selector-design.md`

## Global Constraints

- 零新外部依赖:不引入 SPM 包/C target;实现期只允许读 indexstore-db 公开 `IndexStore.h` 做签名参照,不进任何依赖清单。
- libIndexStore 只 dlopen 不链接;加载/符号缺失/索引异常一律 **exit 3** 让 shell 回落,选择器永不因自身故障挂掉流程。
- 出口语义不变:类列表 → `test.sh --only`;**空映射(含健康闭包为空)→ 全量回落**;无 Swift 改动直接过。
- `affected-tests.sh` 保持 POSIX `/bin/sh`(无进程替换等 bashism,先例注释在文件内)。
- 套件名=文件名约定只对 `*Tests.swift`(80/80 现状);非此后缀的测试文件只记日志不进 `--only`。
- `scripts/*.swift` 进 swiftlint/swiftformat 门禁,写法照仓库规范。

## Review Focus

1. **changed 文件不在索引**(新文件未构建/路径拼错)→ 必须 exit 3 回落,不得当成"零影响"。→ Task 2 步骤验证 exit 3;Task 3 验证回落行。
2. **健康闭包为空** → 回落全量并打印闭包规模,不得静默跑 0 个测试。→ Task 3 步骤 4 验证。
3. **化石 DerivedData 误匹配**(本机 13 个 `NemoNotch-*` 并存)→ 定位必须 `WorkspacePath` 绝对路径全等。→ Task 3 步骤 3 在主检出与 worktree 两场景验证。
4. **record 名形状与预期不符**(前缀/相对路径)→ 探针任务先实测形状并注释在代码里,归一化按实测写。→ Task 1 步骤 4。
5. **扫描过慢使特性无意义**(全量 2:03 是省时的天花板)→ 记录耗时;若闭包计算逼近全量时长,失败回停顿。→ Task 2 步骤 5。

---

### Task 1: dlopen 骨架 + 真索引探针(可行性闸门)

**Files:**
- Create: `scripts/index-affected.swift`

**Interfaces:**
- Produces: `swift scripts/index-affected.swift probe <datastore> <repo-root> <file>` — 打印 record 总数/仓库内 record 数、该文件的 definition USR 列表、首个 USR 的引用文件列表;store 打不开/dylib 缺失 → exit 3。
- Produces(内部,Task 2 消费): dlopen shim(`IndexStore` enum:加载函数指针 + 各 API 的 Swift 调用包装)、record 遍历回调模式。

- [ ] **Step 1: 锁 C API 签名**

WebFetch `https://raw.githubusercontent.com/swiftlang/indexstore-db/main/include/IndexStore/IndexStore.h`,把用到的函数签名与 `INDEXSTORE_SYMBOL_ROLE_DEFINITION`/`REFERENCE` 位值抄进 `scripts/index-affected.swift` 头部注释(实现依据可追溯)。只用:`indexstore_store_create`、`indexstore_records_apply`、`indexstore_record_reader_create/dispose/is_invalid`、`indexstore_record_reader_occurrences_apply`、`indexstore_symbol_usr`、`indexstore_occurrence_roles`(按头里实际名目增删)。

- [ ] **Step 2: 实现 shim 与 `probe` 子命令**

dylib 路径解析:`$DEVELOPER_DIR` 优先,回落 `xcode-select -p`,拼 `Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib`;`dlopen(RTLD_NOW)` 失败或任一 `dlsym` 为空 → stderr 一行原因 + exit 3。回调经 `@convention(c)` 非捕获闭包传给 dlsym 出的函数指针(先声明 `typealias` 再 `unsafeBitCast`)。

- [ ] **Step 3: 对主检出真索引跑探针**

Run: `swift scripts/index-affected.swift probe ~/Library/Developer/Xcode/DerivedData/NemoNotch-enhwkinpekoxtfbkdyatpfivspkn/Index.noindex/DataStore "$PWD" NemoNotch/Services/CompletionToastQueue.swift`
Expected: exit 0;仓库内 record > 200;定义 USR 含 `CompletionToastQueue` 类与其方法;引用文件含 `CompletionFlashService.swift`、`CompletionToastWindowController.swift` 等。同时把 record 名的真实形状(绝对路径?前缀?)写进代码注释。

- [ ] **Step 4: 与 rg 交叉验证一个 USR 的引用面**

任选一个方法级 USR,`rg` 其符号名于 `NemoNotch/`,比对 probe 引用文件列表 ⊇ rg 命中文件(文本超集方向)。对不上 → 回停顿,不硬写。

- [ ] **Step 5: Commit**

`git commit -m "feat(index-affected): dlopen libIndexStore shim + probe 子命令(真索引验证)"`(含头注释里的 API 签名依据)。

### Task 2: 闭包算法 + `closure` 子命令

**Files:**
- Modify: `scripts/index-affected.swift`

**Interfaces:**
- Consumes: Task 1 的 shim 与 record 遍历。
- Produces: `swift scripts/index-affected.swift closure <datastore> <repo-root> <file...>` — stdout 受影响文件(仓库相对路径,每行一个,**含输入文件自身**,排序);任一输入文件不在索引 → exit 3;exit 0 = 索引健康、结果可信。

- [ ] **Step 1: 单遍扫描建表**

遍历全部 record,只留路径在 `<repo-root>/` 下的;每 record 收集 definition USR 集与 referenced USR 集 → `defs: [file: Set<usr>]`、`refs: [usr: Set<file>]`。record reader 用完 dispose,invalid reader 跳过计数(超阈值 → exit 3)。

- [ ] **Step 2: BFS 闭包**

seeds = 输入文件(不在 `defs`/`refs` 键集 → exit 3);worklist 沿 `refs[usr]` 扩文件、文件再供 `defs`,visited 防环,至不动点。输出含 seeds,排序。

- [ ] **Step 3: 真索引端到端验证(传递性)**

Run: `swift scripts/index-affected.swift closure <主检出 DataStore> "$PWD" NemoNotch/Services/CompletionToastQueue.swift`
Expected: exit 0;输出含 `NemoNotchTests/CompletionToastQueueTests.swift`,且严格大于"直接引用者集"(用 Task 1 probe 的单 USR 引用面对比出距离 ≥2 的成员);再跑 `... closure ... NemoNotch/不存在.swift` → exit 3。

- [ ] **Step 4: 边界验证**

输入只有测试文件 → exit 0 且闭包含它自身与引用它的测试辅助;空参数 → usage + 非零(≠3)。

- [ ] **Step 5: 记录耗时(Review Focus 5)**

`time swift scripts/index-affected.swift closure ...` 三次取中位,数字写进提交信息(评审与流程度量的输入)。

- [ ] **Step 6: Commit**

`git commit -m "feat(index-affected): 传递闭包子命令 + 耗时水位 <数字>s"`。

### Task 3: affected-tests.sh 接线 + 回落

**Files:**
- Modify: `scripts/affected-tests.sh`

**Interfaces:**
- Consumes: Task 2 的 `closure` 契约(exit 0/3,stdout 路径列表)。
- Produces: 两级选择器——索引闭包优先、文本匹配回落;最终出口不变(`exec sh scripts/test.sh --only ...` 或全量)。

- [ ] **Step 1: 实现索引定位与调用**

`locate_datastore()`:扫 `~/Library/Developer/Xcode/DerivedData/NemoNotch-*/info.plist`,`plutil -p` 读 `WorkspacePath`,与 `cd "$root" && pwd` 拼的 `$root/NemoNotch.xcodeproj` **绝对路径全等**;首个命中即用,无命中 → 回落。`swift` 不在 PATH → 回落。CLI exit 3 或 stdout 出现仓库外路径 → 回落。

- [ ] **Step 2: 套件映射与接线**

闭包 ∩ `NemoNotchTests/**` 且文件名 `*Tests.swift` → 套件名(basename)+ 改动的测试文件自身照旧并入;成功路径打印 `affected: 选择器=索引闭包(N 文件→M 测试类)`,回落路径打印 `affected: 选择器=文本回落(<原因>)`。文本匹配函数(符号抽取、declared 过滤、grep)一行不动。健康闭包为空 → 仍全量回落 + 打印闭包规模。

- [ ] **Step 3: 两场景定位验证(Review Focus 3)**

主检出与 `.worktree/reminder-kind-tone` 各跑一次定位(只打印不 exec:`sh -x` 观察/grep 输出行),确认各自命中**自己的** DerivedData(WorkspacePath 全等),化石目录不误匹配。

- [ ] **Step 4: 三分支实跑(Review Focus 1/2)**

先跑 ② 拿文本法基线,再跑 ①③ 断言:
② `DEVELOPER_DIR=/nonexistent sh scripts/affected-tests.sh --files NemoNotch/Services/CompletionToastQueue.swift` → 打印"文本回落"且真跑通过,记下选出的类清单作基线;
① 同参数不带屏蔽 → 走索引路径,选出的类 ⊇ ② 的基线,子集真跑通过;
③ 用 CLI 直接找一个"闭包 ∩ NemoNotchTests 为空"的 app 文件(候选 `NemoNotchApp.swift`,闭包结果先验),`--files` 指向它 → 全量回落并打印闭包规模。
三跑均引 `build/test.log` 退出码。

- [ ] **Step 5: Commit**

`git commit -m "feat(affected-tests): 索引闭包选择器 + 文本回落接线(三分支实跑验证)"`。

### Task 4: 文档对账

**Files:**
- Modify: `AGENTS.md`(测试节「影响面测试选择已硬化」句)

- [ ] **Step 1: 更新 AGENTS.md 测试节**

改为两级描述:索引闭包(`scripts/index-affected.swift`,worktree 各自 DerivedData,`WorkspacePath` 定位)→ 文本匹配回落(冷启动/无索引);保留 ripwire 解析不了与"宁多跑不漏跑"句;提及的脚本路径 doc-audit 会核对(文件都在,勿引不存在路径)。

- [ ] **Step 2: 跑 doc-audit**

`sh scripts/doc-audit.sh` → exit 0。

- [ ] **Step 3: Commit**

`git commit -m "docs(AGENTS): 测试选择器两级化(索引闭包→文本回落)"`。

### Task 5: 门禁 + 评审 + 合并

- [ ] **Step 1: 全套门禁**:`sh scripts/lint.sh`、`sh scripts/doc-audit.sh`、`sh scripts/check-arch.sh`、`sh scripts/test.sh`(全量,写锚点)全绿。
- [ ] **Step 2: 勾完全部 checkbox**,再 `sh scripts/review.sh index-affected-tests` 生成模板,`--prompt` 派只读评审子代理(记录原样落 `.reviews/index-affected-tests.md` 单独提交,含耗时水位与三分支证据)。
- [ ] **Step 3: P1/P2 修复 → 重跑门禁 → 增量复审**;P3 默认不修。
- [ ] **Step 4: 主检出 `git feat-done index-affected-tests`**(合并即自动 push + post-merge 构建;若 reminder-kind-tone 会话仍在活跃,先与用户确认部署时序)。
