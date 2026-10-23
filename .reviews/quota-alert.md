# Code Review — feature/quota-alert

Reviewer: 独立评审子代理(zcode 会话,未参与开发;judge ≠ author)
Date: 2026-10-23
Verdict: APPROVED
Scope:  16 files changed, 1575 insertions(+), 10 deletions(-)

```
AGENTS.md
NemoNotch/Helpers/AppDependencies.swift
NemoNotch/Models/AppSettings.swift
NemoNotch/Models/QuotaAlert.swift
NemoNotch/Notch/EdgeBar/EdgeBarAlertCard.swift
NemoNotch/Notch/EdgeBar/EdgeBarCard.swift
NemoNotch/Notch/EdgeBar/EdgeBarController.swift
NemoNotch/Resources/Localizable.xcstrings
NemoNotch/Services/QuotaAlertMonitor.swift
NemoNotch/Settings/Pages/AlertsSettingsPage.swift
NemoNotchTests/EdgeBarAlertCardsTests.swift
NemoNotchTests/QuotaAlertTests.swift
README.md
README_CN.md
docs/superpowers/plans/2026-10-23-quota-alert.md
docs/superpowers/specs/2026-10-23-quota-alert-design.md
```

评审基准:`git diff 684318c...HEAD`(merge-base 三点 diff)。注:两点 diff
`develop..HEAD` 会显示大量 `.zcode/` 删除——那是 develop 侧后来新增的文件,不属于本分支改动。

## Findings

无 P1 / P2。P3 观察三条(均为 spec/plan 明文接受的行为,记录存证,不要求改动):

- **[P3] 拖拽中到达的提醒被静默消费** — `EdgeBarController.swift:325-328`:`autoAlert()` 的
  `defer { knownAlerts = pending }` 在 `guard !isDragging` 提前返回后依然执行,到达边沿被吃掉、
  不开卡。plan Review Focus #2 明文接受("acceptable per spec"),且卡并未丢失:`openBar()`
  (EdgeBarController.swift:632-639)与 pointer 退出的 reclaim 会把待确认卡顶回来。已按代码路径核实。
- **[P3] 到达的提醒卡会夺走悬停中的非审批行卡** — `EdgeBarAlertCard.swift:38-39`(plan 分支:
  开栏 + 非 approvalSelected → `Decision(select: firstArrival)`)。spec 决策 5/6 只保护审批卡
  ("An arriving alert never takes the card from a selected approval");光标仍在行上时 dwell
  重选会把行卡换回,退出时 reclaim 再换回提醒卡。与 spec 一致,非缺陷。
- **[P3] 用户悬停打开(非 autoOpened)的栏也会被待确认卡按住** — `EdgeBarController.swift:309-311`
  `holdsBarForAlert = isOpen && !alerts.alerts.isEmpty`,不依赖 `autoOpened`。spec 决策 5 明文如此
  ("independent of autoOpened");功能默认关(`quotaAlertEnabled ?? false`,AppSettings.swift:293),
  未启用者零行为变化,影响面可控。

### 实现者自报偏差的两条复核(均成立,不引入新问题)

1. **`start()` 先 `evaluate()` 再 `observe()`**(plan 原文只写 observe)——必要:监控器自己的
   5 分钟定时器(`syncPolling`,QuotaAlertMonitor.swift:126-140)是 evaluate 的唯一保底驱动,
   而它本身在 `evaluate()` 里启动;若只 observe,当无任何被观察属性变化(配额无人刷新)时观察
   永不点火 = 轮询活性死锁。对照范型 `WaitingReminderMonitor`(其 30s tick 直接调 evaluate,
   故不需要)。两调用同在 MainActor 上同步执行,无丢失变更窗口。
2. **变异 3 用 `'_ in true'` 替代 plan 的 `'true'`**——复跑原字符串实证:`pending.filter { true }`
   在 Swift 6 编译失败(`EdgeBarAlertCard.swift:31:38: contextual type for closure argument list
   expects 1 argument, which cannot be implicitly ignored`,见 build/test.log);`'_ in true'` 语义
   等价(每个 pending 都算到达),变异照样被抓住(3 红,见下)。

### Plan Review Focus 五条逐项(1-4 读代码核实,5 属部署后)

1. **阈值变更时窗口已超旧阈值** — `QuotaAlertMonitor.swift:84-96`:`lastThreshold != current`
   即清 `above` + `alerts` 重启检测;`above` 清空后不可能发 recovered(先决条件是 `above.contains`)。
   抬高阈值只会在下一轮把仍超新阈值的窗口当**新到达**发 exceeded。正确。
2. **拖拽中到达** — 见 P3 第一条;`knownAlerts` 经 defer 保持一致,不损坏。
3. **审批答完且有提醒待确认** — 栏不被误收(`autoCard` 收起分支加了 `alerts.alerts.isEmpty`,
   EdgeBarController.swift:289);行消失时同一 refresh 内 `revalidateSelection` deselect →
   `autoAlert` 无到达分支(`isOpen && selectedRow == nil` → reclaim)立刻把提醒卡顶回
   (refresh 顺序 :203-206);行卡仍在时退出路径 reclaim 顶回(:561-570)。无搁浅卡。
4. **功能/边栏关闭时有待确认卡** — 监控器 `evaluate` 不活跃分支清 alerts+above并停表
   (:75-83);控制器观察 `alerts.alerts`(:166)触发 refresh;`holdsBarForAlert` 随清空失效,
   autoOpened 栏按原路径自收。无按死不放的栏。
5. **部署后实测** — N/A(本评审不部署);建议合并部署后按 plan 原文烟测。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:三个新套件全部以具体输入调被测单元、断言字面输出(events/above/ids/Decision);
  被测代码若全返默认值,`crossingUpFiresExceededOnce`/`aFirstReadingAlreadyOverFires`/
  `anEventBecomesAPendingAlert`/`anArrivalOpensTheClosedBar` 等会立刻红。变异 3/3 被抓住(见下),有牙。
- [x] **证据纪律**:本评审独立复跑了全部验证命令(测试、变异、xcstrings、doc-audit),退出码见下;
  plan 各 Task 的验证声明与实际一致。
- [x] **Swift 6 并发**:监控器 `@MainActor @Observable`;模型全 Sendable 值类型;Timer block 内只
  `Task { @MainActor [weak self] }` hop(QuotaAlertMonitor.swift:129-131);`deinit` 的
  `MainActor.assumeIsolated { timer?.invalidate() }` 与 UsageQuotaService.swift:77 逐字同款
  (同为 AppDependencies 持有的 app-lifetime 对象);观察重臂顺序与 WaitingReminderMonitor.observe
  逐字相同(re-arm 在 evaluate 之前)。全量测试构建通过 = Swift 6 编译级证据。
- [x] **最小改动**:每个 hunk 都能映射到 plan 步骤;`EdgeBarCard.swift` 仅两处(暴露 reportingFrame
  扩展、卡片分支前置),无顺手重构。两点 diff 里的 `.zcode/` 删除是 develop 侧新增,不属本分支。
- [x] **错误路径**:瞬时抓取失败不读作恢复(`readings` 只收 `.valid` 且有 tiers;缺失键保留状态,
  `aMissingWindowKeepsItsState` 有测);清状态/发卡/确认均 `.info` 日志(category "QuotaAlert"),
  无吞错、无假绿。
- [x] **坑总目录对照**:复用审批 auto-card 机制(审批优先:`autoCard` 先于 `autoAlert` 跑,且
  `EdgeBarAutoCard.plan` 在选中卡非审批时可夺卡——CLI 被扣住,响度次序正确);卡 id 前缀 `alert:`
  与 `usage:`(EdgeBarUsage.swift:155)及裸会话 id 三者无碰撞;`TimelineView(.everyMinute)` 与
  EdgeBarUsageCard.swift:174 同款(分钟级 tick,无逐帧 CPU 顾虑);卡片仅选中时挂载,无 opacity
  式隐藏;无 repeatForever;`select` 清 buttonRects 防止会话卡按钮残留命中。
- [x] **文档同步**:AGENTS.md「Edge Bar」节新 bullet、README.md/README_CN.md 各一句,均按 plan;
  doc-audit 退出码 0。

## 评审方法与复验命令(worktree 内,退出码为准)

- `python3 scripts/xcstrings.py check` → exit 0(canonical);8 个新键
  (settings.quota_alert.* ×4、edge_bar.alert.* ×4)en+zh-Hans 全在,值与 plan 一致;新文件无硬编码 UI 字符串。
- `sh scripts/test.sh --only QuotaAlertDetectorTests` → 7/7 通过,exit 0
- `sh scripts/test.sh --only QuotaAlertsTests` → 5/5 通过,exit 0
- `sh scripts/test.sh --only EdgeBarAlertCardsTests` → 9/9 通过,exit 0
- `sh scripts/test.sh --only EdgeBarAutoCardTests` → 12/12 通过,exit 0(审批自动卡回归无扰)
- `sh scripts/test.sh`(全量)→ **523/523 通过,exit 0**
- `sh scripts/mutate.sh NemoNotch/Models/QuotaAlert.swift 'utilization >= threshold' 'utilization > threshold' --only QuotaAlertDetectorTests`
  → exit 0,变异被抓住(2 红)
- `sh scripts/mutate.sh NemoNotch/Models/QuotaAlert.swift 'threshold - Self.hysteresis' 'threshold' --only QuotaAlertDetectorTests`
  → exit 0,变异被抓住(1 红)
- `sh scripts/mutate.sh NemoNotch/Notch/EdgeBar/EdgeBarAlertCard.swift '!previous.contains($0)' '_ in true' --only EdgeBarAlertCardsTests`
  → exit 0,变异被抓住(3 红)
- 追加:`mutate.sh` 同位原字符串 `'true'` → Swift 6 编译错(test.log:741),证实偏差 2 的必要性
- `sh scripts/doc-audit.sh`(主检出)→ exit 0
- 未跑 `./build.sh`、未 merge/push/feat-done(按评审约束)

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 684318cc195b79677db48ca99759c78aeabfffe4...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
