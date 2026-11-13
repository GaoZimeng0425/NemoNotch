# 防休眠双开关 + 「谁在阻止休眠」面板 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task(本仓恒选,主对话实现). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增零弹窗的「空闲不休眠」租约开关(状态跨启动保留)+ 设置页「谁在阻止休眠」两层面板;现有合盖不休眠(disablesleep)路线一行不动。

**Architecture:** 纯解析层把 `IOPMCopyAssertionsByProcess` 返回的按 PID 分组字典解析/过滤/聚合(全部公开 API,运行时字段集已实测);`KeepAwakeService` 增持一份独立的用户意图断言(`"NemoNotch Idle Keep Awake"`,与第二层 `"NemoNotch Keep Awake"` 分持),设置持久化 + `refresh()` 对账自愈;设置页新增开关行与面板区块,`.task` 驱动 10s 刷新(离屏自动停)。

**Tech Stack:** Swift 6 / SwiftUI / IOKit(pwr_mgt)/ Swift Testing。

**Spec:** `docs/superpowers/specs/2026-11-13-keepawake-idle-toggle-assertions-panel-design.md`

## Global Constraints

- **开关 B(合盖不休眠)机制、设置、行为一行不动**(spec 反目标;diff 里 `setEnabled`/`restoreForQuit`/对账段不得改)。
- A 默认关;断言名 `"NemoNotch Idle Keep Awake"`;断言类型 `PreventUserIdleSystemSleep`。
- 零私有 API、零新权限(全部走公开 `IOPMCopyAssertionsByProcess` / `IOPMAssertionCreateWithName`)。
- UITestMode 不持真断言(镜像 `KeepAwakeService.swift:443` 的门禁);设置持久化照常。
- 新 UI 字符串进 `Localizable.xcstrings`(en + zh-Hans),经 `scripts/xcstrings.py` 归一。
- 测试只用 Swift Testing;跑测试用 `sh scripts/test.sh`,lint 用 `sh scripts/lint.sh`。
- 实测字段集(2026-11-13 本机探针,头文件没写全,以此为准):每条断言字典含 `AssertPID`/`Process Name`/`AssertName`/`AssertType`/`AssertionTrueType`/`AssertStartWhen`(Date);可选 `AssertTimeoutTimeLeft`+`AssertTimeoutUpdateTime`(均为秒)、`AssertionOnBehalfOfPID`。ZCode 实测形状:`AssertType=NoIdleSleepAssertion` 但 `AssertionTrueType=PreventUserIdleSystemSleep`——**归族按 TrueType,缺失时把 `NoIdleSleepAssertion` 归 `PreventUserIdleSystemSleep`**。

## Review Focus

1. **AssertType 与 TrueType 不一致**(ZCode 形状)→ 按 TrueType 归族不漏(Task 1 测试)。
2. **timeout 已过期**(TimeLeft 减去流逝时间成负)→ 剩余钳 0,不显示负数(Task 1 测试)。
3. **自家两份断言进面板**(第二层/A 同 pid 两条)→ 按 ownPID 过滤(Task 1 测试)。
4. **缺字段/坏形状条目**(无 AssertPID、非字典)→ 跳过不崩,空字典 → 空列表(Task 1 测试)。
5. **A 断言静默丢失**(powerd 重启等)不自愈 → `refresh()` 对账重建;验证靠手测步骤(诚实标注:无纯单测,Task 2 手测步骤 4)。

---

### Task 1: 外部断言纯解析层(解析/过滤/聚合/时间分量)

**Files:**
- Create: `NemoNotch/Services/ExternalSleepAssertions.swift`
- Test: `NemoNotchTests/ExternalSleepAssertionsTests.swift`

**Interfaces:**
- Consumes: 无(纯层;IOKit 调用在 Task 2/3 侧,不进此文件)。
- Produces(后续任务依赖的精确签名):
  - `struct ExternalSleepAssertion { let pid: Int32; let processName: String; let name: String; let trueType: String; let startedAt: Date; let timeoutRemaining: TimeInterval?; let onBehalfOfPID: Int32? }`
  - `struct ExternalSleepAssertionSummary { let pid: Int32; let processName: String; let count: Int; let oldestStartedAt: Date; let timeoutRemaining: TimeInterval?; let onBehalfOfPID: Int32? }`
  - `enum ExternalSleepAssertions`:`parse(byPID: [AnyHashable: Any], now: Date, ownPID: Int32) -> [ExternalSleepAssertion]`、`summarize([ExternalSleepAssertion]) -> [ExternalSleepAssertionSummary]`(按 pid 聚合,oldest 取最早 startedAt,remaining 取组内最小非 nil,按 oldestStartedAt 降序)、`ageComponents(startedAt:now:) -> (hours: Int, minutes: Int)`、`remainingMinutes(_ remaining: TimeInterval?) -> Int?`(向下取整)。
  - 常量:`noiseProcessNames: Set<String> = ["powerd", "WindowServer", "runningboardd", "bluetoothd"]`;`systemSleepFamilyTypes: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep"]`。

- [x] **Step 1: 写失败测试** — fixture 用真实探针形状(顶层数组:`AnyHashable(NSNumber(pid))` → `[[String: Any]]`):ZCode 形状(TrueType 归族)、caffeinate 形状(Timeout 键,`TimeLeft=211`/`UpdateTime=now-89` → 剩 211-89+流逝容差≈122…按断言字面值构造:TimeLeft=100、UpdateTime=now-40 → 期望 60)、powerd/bluetoothd 噪音过滤、ownPID 两条(Keep Awake/Idle Keep Awake)过滤、`UserIsActive` 类型出族、缺 AssertPID 条目跳过不崩、空字典 → []、同 pid 两条聚合(count=2/oldest/最小 remaining)、过期钳 0、onBehalfOfPID 透传、`ageComponents`/`remainingMinutes` 数学(含 nil)。判别剃刀自检:解析函数对「到处缺字段」的输入若还能返回非空期望,测试无效。
- [x] **Step 2: 跑测试确认红** — `sh scripts/test.sh --only ExternalSleepAssertionsTests`(编译失败即红:类型不存在)。
- [x] **Step 3: 实现** — 解析规则全部按 Global Constraints 的字段集;`timeoutRemaining = TimeLeft - now.timeIntervalSince(UpdateTime)`,钳 ≥0,任一键缺失 → nil;`startedAt` 非 Date → 兜底 `now`(条目仍列出);`processName` 缺失 → `"pid \(pid)"`。
- [x] **Step 4: 跑测试确认绿 + 变异验证** — `sh scripts/test.sh --only ExternalSleepAssertionsTests` 绿;`sh scripts/mutate.sh NemoNotch/Services/ExternalSleepAssertions.swift 'PreventUserIdleSystemSleep' 'PreventSystemSleepX' --only ExternalSleepAssertionsTests` 须红(归族过滤有牙)。
- [x] **Step 5: Commit** — `feat(keepawake): 外部休眠断言纯解析层(解析/过滤/聚合)`

### Task 2: A 开关 — 设置键 + 断言生命周期 + 对账自愈

**Files:**
- Modify: `NemoNotch/Models/AppSettings.swift`(仿 `keepAwakeRestoreOnQuit` 三段式:约 :224 键常量、:236 didSet、:321 读默认)
- Modify: `NemoNotch/Services/KeepAwakeService.swift`(断言持有、`start()` 尾部恢复、`refresh()` 内自愈、`isolated deinit` 释放)

**Interfaces:**
- Consumes: `IOPMAssertionCreateWithName("PreventUserIdleSystemSleep", kIOPMAssertionLevelOn, "NemoNotch Idle Keep Awake", &id)`;`UITestMode.isTestHost` 门禁(:443 范式);`holdIdleSleepAssertion`(:441)的日志节流范式(`idleSleepAssertionFailureLogged`)。
- Produces(Task 3 依赖):`private(set) var isIdleKeepAwakeActive: Bool`、`private(set) var idleKeepAwakeError: String?`、`func setIdleKeepAwake(_ on: Bool)`、`func restoreIdleKeepAwakeFromSettings()`;AppSettings 新增 `var keepAwakeIdleEnabled: Bool`(key `"keepawake.idleEnabled"`,默认 `false`)。

- [x] **Step 1: AppSettings 键** — 三段式照抄现有键模式,默认 false。
- [x] **Step 2: 服务侧** — `idleKeepAwakeAssertion: IOPMAssertionID`(0=未持)独立于 `idleSleepAssertion`;`setIdleKeepAwake` 门禁 UITestMode(不持真断言)后 create/release,失败写 `idleKeepAwakeError`(成功清空);`start()` 尾部调 `restoreIdleKeepAwakeFromSettings()`(设置开 → 建);`refresh()` 末尾自愈:设置开 && 断言 ID==0 && 无错误 → 重建(每次 refresh 重试可接受——无弹窗;日志只记状态转移);`isolated deinit` 释放两份断言。**不碰** `setEnabled`/`restoreForQuit`/`needsRestoreOnQuit` 及对账段任何行。
- [x] **Step 3: 门禁** — `sh scripts/test.sh` 全量绿 + `sh scripts/lint.sh` 绿(B 未动,既有 KeepAwakeTests 不得变红)。
- [x] **Step 4: 手测(梯级 5)** — `./build.sh` 部署后:设置开 A → 终端 `pmset -g assertions | grep "Idle Keep Awake"` 见条目;退出 app → 条目消失;重开 app(设置仍开)→ 条目自动回来;`defaults read com.nemo.BrightnessApp.NemoNotch keepawake.idleEnabled` 验持久化。四步各留一行结果进 commit message 或评审记录。
- [x] **Step 5: Commit** — `feat(keepawake): 空闲不休眠开关(租约版,状态跨启动保留)`

### Task 3: 设置页 UI — A 开关行 + 两层面板 + 10s 刷新

**Files:**
- Modify: `NemoNotch/Settings/Pages/KeepAwakeSettingsView.swift`
- Modify: `NemoNotch/Services/KeepAwakeService.swift`(只加:外部断言读取)
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: Task 1 全部类型;Task 2 的 `isIdleKeepAwakeActive`/`idleKeepAwakeError`/`setIdleKeepAwake`;既有 `isEnabled`/`isOwned`。
- Produces: `private(set) var externalSummaries: [ExternalSleepAssertionSummary]`、`private(set) var externalOnBehalfNames: [Int32: String]`、`func refreshExternalAssertions(now: Date = .init)`(调 `IOPMCopyAssertionsByProcess`,`takeRetainedValue` 转 `[AnyHashable: Any]` → `ExternalSleepAssertions.parse(ownPID: ProcessInfo.processInfo.processIdentifier)`,归因名 `NSRunningApplication(processIdentifier:)?.localizedName ?? "pid \(n)"`)。

- [x] **Step 1: 服务读取方法** — 如上;读失败(API 返回非 success)清空 summaries 并 `.warn` 一条(记状态转移)。
- [x] **Step 2: UI** — 布局:第一 Section 顶部加 A toggle(get 绑 `settings.keepAwakeIdleEnabled`,set 写设置 + `Task { await keepAwake.setIdleKeepAwake($0) }`)+ caption detail;B 区(statusRow/lastError)原样。新 Section「谁在阻止休眠」置于选项区之前:空态文案;`ForEach(externalSummaries)` 行 = 进程名(count>1 加 `×N`)+ 归因名(有则 `(替 xxx)`)+ 年龄(`ageComponents` → 本地化字符串);有 remaining 追加 `剩 N 分钟`;分隔线后一行合盖层 = `isEnabled ? (isOwned ? 「开启(我们)」 : 「开启(未知来源)」) : 「关闭」`。刷新:`.task { while !Task.isCancelled { await keepAwake.refreshExternalAssertions(); try? await Task.sleep(for: .seconds(10)) } }`(离屏自动取消,无 Timer 状态)。
- [x] **Step 3: 本地化** — 新 key(en + zh-Hans):`settings.keepawake.idle.enable`/`.idle.detail`/`panel.header`/`panel.empty`/`panel.clamshell`/`panel.clamshell.owned`/`panel.clamshell.external`/`panel.clamshell.off`/`panel.remaining`;走 `scripts/xcstrings.py format`。
- [x] **Step 4: 门禁 + 手测** — `sh scripts/test.sh` + `sh scripts/lint.sh` + `sh scripts/doc-audit.sh` 绿;`./build.sh` 后设置页:面板应列出 ZCode(11h 级)等真实条目、不含 NemoNotch 自己;合盖层状态与 B 开关联动;离开设置页 10s 后日志无刷新记录(定时器停)。
- [x] **Step 5: Commit** — `feat(keepawake): 「谁在阻止休眠」两层面板 + 空闲开关 UI`

### Task 4: 文档对账 + cookbook 条目

**Files:**
- Modify: `README.md`、`README_CN.md`(功能清单加一句)
- Modify: `AGENTS.md` 防休眠节(只加坑/不变量,不写功能说明:A 与第二层断言分持且命名区分;A 由 refresh 对账自愈;面板噪音过滤名单;**`IOPMCopyAssertionsByProcess` 运行时字段比头文件文档多——字段集以本仓探针记录为准,别按头文件下"不存在"结论**)
- Modify: `../macos-playbook`(独立仓库,同一提交):`IOPMCopyAssertionsByProcess` 运行时字段集条目(含 TrueType 归族、Timeout 键、OnBehalfOfPID)
- Modify: `docs/superpowers/specs/…` 不动;本 plan 完工后随 feat-done 挪 `archive/`(既有惯例)

- [x] **Step 1: 四处文档同一提交改齐** — 上述清单;AGENTS 只加不变量与坑。
- [x] **Step 2: 门禁** — `sh scripts/doc-audit.sh` 绿(引用路径存在性)+ `sh scripts/lint.sh`。
- [x] **Step 3: Commit** — `docs(keepawake): 双开关与断言面板的文档对账 + cookbook IOPMCopyAssertionsByProcess 字段集`

---

## 收尾(主对话例行)

门禁全绿 → `sh scripts/review.sh <name>` 生成评审记录 → 未参与开发的会话评审(只给 diff+AGENTS.md,不带 plan)→ 回流修 P1/P2 → 主检出 `git feat-done`(合并即自动 push develop + 自动构建部署)→ reflect。
