# Code Review — feature/keepawake-idle-toggle

Reviewer: ZCode 独立评审会话(GLM-5.3,未参与开发)
Date: 2026-11-13
Reviewed-Head: cde2832
Verdict: APPROVED
Scope:  11 files changed, 968 insertions(+)

```
AGENTS.md
NemoNotch/Models/AppSettings.swift
NemoNotch/Resources/Localizable.xcstrings
NemoNotch/Services/ExternalSleepAssertions.swift
NemoNotch/Services/KeepAwakeService.swift
NemoNotch/Settings/Pages/KeepAwakeSettingsView.swift
NemoNotchTests/ExternalSleepAssertionsTests.swift
README.md
README_CN.md
docs/superpowers/plans/2026-11-13-keepawake-idle-toggle-assertions-panel.md
docs/superpowers/specs/2026-11-13-keepawake-idle-toggle-assertions-panel-design.md
```

## Findings

- **[P1] NemoNotch/Services/KeepAwakeService.swift:438-443 — `Dictionary(uniqueKeysWithValues:)` 在重复归因 pid 下运行时崩溃。** `parsed` 是未聚合的全部断言;两条断言挂同一 `AssertionOnBehalfOfPID`(coreaudiod 替同一 app 的两个音频流各挂一条——这正是 spec/README 点名要展示的形状)时重复 key 直接 trap。已梯级 4 验证机制:独立 Swift 脚本构造 `[(57602, "X"), (57602, "X")]` → `Fatal error: Duplicate values for key: '57602'`(Swift 6.4.2 本机)。诚实披露：本机当下 5 条断言无重复归因(只读探针实测)，故作者手测与我的复跑都没踩到；判定基于崩溃机制 + 输入形状在功能目标场景内(Zoom/录音类 app 一开多流即触发，设置页 10s 内必炸，CrashGuard 循环三次后放弃)。修法一句话:`Dictionary(parsed.compactMap { … }, uniquingKeysWith: { first, _ in first })`。此路径无单测覆盖(服务层)，修复后建议补一条纯层测试防回归(把「归因表构建」抽进 `ExternalSleepAssertions` 即可测)。**→ cde2832 已修，见增量复审。**
- **[P2] NemoNotch/Settings/Pages/KeepAwakeSettingsView.swift:121 + KeepAwakeService.swift:435 — 无 timeout 条目的年龄显示冻结。** `refreshExternalAssertions` 只在 summaries 变化时写回(正确的 @Observable 纪律)，但无 timeout 条目的 summaries 内容恒定 → 永不写回 → `ForEach` 行 body 不重算 → 行内 `Date.now` 的「已持续 N 时 M 分」冻结在首次渲染。带 timeout 条目(caffeinate)在场时整列会跟着每 10s 更新；但纯常驻断言(典型如 ZCode,作者手测自己就是 13h 条目)场景下分钟/小时数不动，用户可感知。梯级 2(代码路径推演，未跑真 app)。修法一句话：把年龄的分钟粒度纳入写回判定(如 summaries 比较时附带 `now` 的分钟桶)，或行内年龄改用系统 `Text(timerInterval:)` 自动刷新(零轮询，repo 纪律兼容)。**→ cde2832 已修，见增量复审。**
- **[P3] NemoNotch/Services/KeepAwakeService.swift:382 — `idleKeepAwakeError` 在失败分支每 10s 无条件重写相同值。** @Observable 写通知不 diff,设置页打开且创建持续失败时每 10s 触发一次无谓重算——同函数 15 行之上刚为 `externalSummaries` 写了「只在有变化时写回」的注释，这个字段漏罩。修法：套同款 `if idleKeepAwakeError != newError` 守卫。**→ 已修。**
- **[P3] NemoNotch/Services/KeepAwakeService.swift:124 — `isIdleKeepAwakeActive` 零消费者**(UI、测试、菜单栏均不读；grep 全仓仅 3 处定义与赋值)。plan Task 3 的 Interfaces 声称 Consumes 它，实现没接；spec 约束「状态行如实『开启(未生效)』」实际只由 error caption 表达(toggle 永远显示开)。要么在 UI 接上状态行，要么删掉这个属性。**→ 已删。**
- **[P3] NemoNotch/Models/AppSettings.swift:224 — 键名 `keepawake.idleEnabled` 与兄弟键 `keepAwake.lidDisplayOff`/`keepAwake.restoreOnQuit` 风格不一致**(小写 w)。字符串是 plan 拍的、README 手测也用它，功能无碍；但发布后键名锁死、改名要迁移——合并前是最后的免费改名窗口，建议对齐 `keepAwake.idleEnabled`。**→ 已对齐。**
- **[P3] plan 与实现措辞漂移一处**：plan Task 1 Interfaces 写 summarize「按 oldestStartedAt 降序」，实现与测试是升序(最老排最上面——UI 语义正确，注释自洽)。plan 即将 archive,顺手改 plan 措辞即可，不动代码。**→ 已对齐(升序+删除注记)。**
- **[P3] Review Focus 第 5 条的验证缺口**：A 断言「静默丢失 → refresh() 重建」路径没有手测记录(commit message 的梯级 5 手测覆盖的是启动恢复/退出回收，不含丢失重建)，也无单测(plan 诚实标注)。梯级 2(代码阅读:`refresh()` 每 10s 末尾 `holdIdleKeepAwakeAssertion(settings?.keepAwakeIdleEnabled ?? false)` 幂等重建，路径存在且正确)。合并后值得补一次手测：开 A → `sudo killall powerd`(或等价丢失)→ 10s 内断言回来。**→ 作者留存，合并后补手测(接受，梯级 2 在)。**

## 审查清单(评审者逐项过，不适用项标 N/A)

- [x] **判别剃刀**：通过。14 条测试全部字面期望(60/0/count==1/pid 排序/nil 透传/聚合最小值)，fixture 取自真实探针形状；解析器对缺字段输入返回空而非凑数，有鉴别力。变异验证我独立复跑:`PreventUserIdleSystemSleep→PreventSystemSleepX` 注入后套件 `** TEST FAILED **`(红)，文件恢复、工作树干净——守卫有牙(梯级 4)。
- [x] **证据纪律**：通过。commit message 带梯级 4/5 声明：Task 2 手测「基线 0 → 开+重启 1 → 退出 0 → 重启 1 → 清场 0」、Task 3 活体验证(ZCode 13h7m / caffeinate 剩 2m / 噪音全滤)，且诚实标注「own-pid 过滤在探针视角不适用，app 内由单测覆盖」「UI 截图跳过」。我亲跑复验：lint 0 / doc-audit 0 / check-arch 0 / affected-tests 213 全过(含 KeepAwakeTests——B 既有测试不红)/ xcstrings check canonical。
- [x] **Swift 6 并发**：通过。新代码全在 @MainActor 服务内，`NSRunningApplication(processIdentifier:)` 主线程调用;`isolated deinit` 释放两份断言沿既有模式;`.task` 循环离屏取消正确(sleep 抛 CancellationError 被吞后 `isCancelled` 退出)。无新 Sendable 边界。
- [x] **最小改动**：通过。KeepAwakeService 改动全是增量(diff 零删除行)，`setEnabled`/`restoreForQuit`/对账段/`holdIdleSleepAssertion` 一行未动——「B 一行不动」硬约束满足，KeepAwakeTests 全绿佐证。
- [x] **错误路径**：基本通过。断言创建失败写 `idleKeepAwakeError` + warn 一次(节流)；枚举读失败清空 + warn 一次。扣分项见 P3(idleKeepAwakeError 每 10s 重写)。
- [x] **坑总目录对照**：通过。「别按头文件下『不存在』的结论」与 LidMonitor `AppleClamshellState` 坑同型、新两条不变量与防休眠节口径一致；A 自愈与 B「刻意不自动恢复」纪律的相容性论证成立(弹窗代价是那条纪律的存在理由，A 无此代价)。`IOPMAssertionCopyMatching` 私有且符号未导出的警告已写进 AGENTS.md。
- [x] **教训候选**：见下。
- [x] **文档同步**：通过。README×2、AGENTS.md(只加不变量与坑，不写功能说明)、cookbook(macos-playbook/system-sensing/sleep-assertions.md,含 TrueType 归族/Timeout 键 Date 语义/OnBehalfOfPID/噪音名单，`last_verified` 锚到 e0be2e9)四处齐。plan 全部任务已勾，plan-audit 无裸框可预检。

## plan Review Focus 逐条复核

1. TrueType vs AssertType 不一致(ZCode 形状)→ `trueTypeWinsOverLegacyAssertType` 覆盖，归族按 TrueType ✓
2. timeout 过期成负 → `expiredTimeoutClampedToZero` 钳 0 ✓
3. 自家两份断言(同 pid 两条)→ `ownPidAssertionsFiltered` ✓
4. 缺字段/坏形状 → `malformedEntriesSkippedNotCrashed`(非字典元素、无 AssertPID、空字典)✓
5. A 断言静默丢失自愈 → 代码路径在(`refresh()` 末尾对账)，验证缺口见 P3 最后一条。

### 教训候选

- **「解析层有测试 ≠ 集成点安全」**(KeepAwakeService.swift:438):纯层 `ExternalSleepAssertions` 测了 14 条，但消费它的 `Dictionary(uniqueKeysWithValues:)` 在服务层裸用——`parsed` 的多对一形状(多条断言共享归因 pid)在纯层是合法输入、在字典构造点是 trap。判据：凡把「数组→Dictionary(uniqueKeysWithValues:)」接在枚举/解析输出后面的，输入天然可能重复 key,必须 `uniquingKeysWith`;可考虑加进 check-arch B 档(新增行的 `uniqueKeysWithValues:` 模式)。
- **「只在有变化时写回」纪律要罩住函数里全部 @Observable 写点**(KeepAwakeService.swift:382):纯层 `ExternalSleepAssertions` 测了 14 条，但消费它的 diff 守卫写了一个字段后，同函数后续赋值容易被读成「已经管住了」。判据：函数内每处对外可见属性赋值逐一点名过一遍。
- **视图内 `Date.now` 只在数据变化时刷新**(KeepAwakeSettingsView.swift:121):把「随时间变化的展示值」放进依赖静态数据的 body,渲染时钟跟着数据走而不是跟着时间走；判据：凡 body 里出现 `Date.now`,问一句「上游数据不变时这个值会动吗」。

## 增量复审(b72dedb..cde2832)

**范围**:`git diff b72dedb..HEAD` = 1f95eba(评审记录落盘，上轮全文原样入库，非代码)+ cde2832(修复提交)。逐项核对修复声明，不信自述，关键验证全部亲跑。

### P1 修复核对 — 已修，守卫有牙(独立复跑)

- 纯层新增 `ExternalSleepAssertions.uniqueOnBehalfPIDs(_:)`(NemoNotch/Services/ExternalSleepAssertions.swift:118-124):保序去重，`seen.insert(pid).inserted` 惯用法正确；服务层 KeepAwakeService.swift:438-442 改为「去重列表 → map 出 (pid, name) → Dictionary(uniqueKeysWithValues:)」,key 必唯一，trap 消除。修复与根因因果正对(根因=未去重数组进 uniqueKeysWithValues,修法=去重)，顺带把 `NSRunningApplication` 查询从「每条归因断言一次」降到「每唯一 pid 一次」。
- 守卫测试 `uniqueOnBehalfPIDsDeduplicatesForDictionarySafety`(NemoNotchTests/ExternalSleepAssertionsTests.swift:171-209):两条断言同归因 57602 + 一条 nil → `pids == [57602]`、去重后字典构造不炸、空数组 → [],字面期望，判别剃刀过——被测函数若变成恒空/恒不去重，测试必红。
- **变异独立复跑(梯级 4)**:`sh scripts/mutate.sh … 'out.append(pid)' 'out.removeAll()' --only ExternalSleepAssertionsTests` → 「✅ 变异被抓住：测试变红(失败 1 个，通过 13),证据：退出码 65」,文件已恢复、工作树干净(`git status --short` 无输出)。
- **红→绿可重放性(梯级 3,明说)**：守卫测试与修复同在 cde2832,git 历史无独立红态提交；红态可由「上轮 b72dedb 无 `uniqueOnBehalfPIDs` 符号 → 测试引用不存在符号，编译失败即红」推出，非亲见。

### P2 修复核对 — 已修，方案优于我上轮建议

- KeepAwakeSettingsView.swift:141:年龄改 `Text(.currentDate, format: .reference(to: summary.oldestStartedAt))`——AGENTS.md 完成闪光卡同款系统自动刷新(手册明文：「用系统 `Text(.currentDate, format: .reference(to:))` 自动刷新，别自己挂定时器」),渲染时钟跟着时间走、不依赖上游数据变化，冻结根因消除且零轮询零状态。这正是仓库纪律点名的模式，比我在上轮给的「分钟桶比较」修法更干净。
- `ageComponents` 纯函数、其测试、xcstrings key `settings.keepawake.panel.age %lld %lld` 三处同删;全仓 grep 代码/测试/xcstrings 零残留(唯一命中在 plan 历史文本，见下)。附带核对:`.reference(to:)` 显示系统风格相对时间(「2 小时前」)，与原「11 h 23 min」格式有差，本地化随系统语言，可接受。

### P3×4 修复核对 — 全清

- `idleKeepAwakeError` 写回守卫：成功分支 `if idleKeepAwakeError != nil`、失败分支 `if idleKeepAwakeError != message`(KeepAwakeService.swift:374-381),两向都罩住了。
- `isIdleKeepAwakeActive`:三处全删，代码/测试 grep 零残留。
- 键名 → `keepAwake.idleEnabled`(AppSettings.swift:224),代码零旧键残留；本机 UserDefaults 里上轮手测写入的旧键 `keepawake.idleEnabled` 残值无害(旧键已无人读，新键默认 false)。
- plan Interfaces 行已改「升序=最老排最上」+ `~~ageComponents~~` 删除注记。

### 本轮新发现(不阻塞)

- **[P3, 措辞] plan 历史步骤行未同步注记**:plan 第 61 行(Task 2 Produces 仍列 `isIdleKeepAwakeActive` + 旧键名 `keepawake.idleEnabled`)、第 77 行(Task 3 Consumes 仍列 `isIdleKeepAwakeActive`)、第 47/81 行(fixture 清单与 UI 步骤仍提 `ageComponents`)——作者只在 Interfaces 契约行(44)加了删除注记，这些是「当时下了什么任务」的历史快照，archive 后即历史，可接受；但与 line 44 的处理不一致，加一句删除注记更干净。定性：文档措辞，不阻塞，留作者裁量。

### 门禁复验(全部亲跑，退出码在案)

- `sh scripts/lint.sh` → exit 0
- `sh scripts/doc-audit.sh` → exit 0
- `sh scripts/check-arch.sh` → exit 0
- `sh scripts/affected-tests.sh` → 「✅ 测试通过(退出码 0)」,213 用例全过 0 失败(含 KeepAwakeTests,B 既有行为不红的旁证；选择器闭包 85 文件 31 类，同上轮)
- `sh scripts/mutate.sh`(P1 守卫)→ 变异被抓住，退出码 65,文件恢复，工作树干净
- `python3 scripts/xcstrings.py check` → canonical
- 修复未引入新问题：lint 编译过、213 测试绿、B 相关代码段(diff 核对)仍零触碰。

### 遗留项

1. plan 历史步骤行的注记不一致(上文本轮 P3,可选)。
2. 作者自报的合并后手测：A 断言静默丢失(powerd 重启等)→ `refresh()` 10s 内重建，梯级 5 补课(上轮 P3,代码路径梯级 2 已核)。

**改判说明**:CHANGES_NEEDED → **APPROVED**。P1 修复因果正确、守卫测试有牙(变异独立复跑红)、P2 修复落在仓库手册背书的同款模式上、P3 四项全清且零残留；遗留两条均为措辞级/手测补课级，不构成合并阻塞。我愿意为这个合并背书。

---

**证据完备度声明**：本轮全部结论亲跑验证(六个门禁/验证命令的退出码与日志在案);P1 守卫的变异验证梯级 4,红→绿历史梯级 3(缺符号编译失败可推出,非亲见);P2 修复效果未在运行中的 app 目验(评审约束禁跑 build.sh),判定基于代码形态 + AGENTS.md 同款模式的既有实证背书。
