# Code Review — feature/remove-pomodoro-system-launcher

Reviewer: independent review subagent (Claude, fresh context; did not author this branch)
Date: 2026-11-01
Reviewed-Head: 87fd2af
Verdict: APPROVED
Scope:  57 files changed, 302 insertions(+), 6498 deletions(-)

```
AGENTS.md
NemoNotch/Helpers/AppDependencies.swift
NemoNotch/Helpers/UITestSeeder.swift
NemoNotch/Models/AppItem.swift
NemoNotch/Models/AppSettings.swift
NemoNotch/Models/PomodoroPhase.swift
NemoNotch/Models/PomodoroRecord.swift
NemoNotch/Models/Tab.swift
NemoNotch/Models/TodoTask.swift
NemoNotch/NemoNotchApp.swift
NemoNotch/Notch/Badge/BadgeGrouping.swift
NemoNotch/Notch/Badge/BadgeIconView.swift
NemoNotch/Notch/Badge/BadgeItem.swift
NemoNotch/Notch/Badge/BadgeViewModel.swift
NemoNotch/Notch/Badge/PomodoroPieView.swift
NemoNotch/Notch/CompletionToastView.swift
NemoNotch/Notch/NotchView.swift
NemoNotch/Notch/QuickStartWindow.swift
NemoNotch/Notch/QuickStartWindowController.swift
NemoNotch/Notch/TabBarView.swift
NemoNotch/Resources/Localizable.xcstrings
NemoNotch/Services/CompletionDetector.swift
NemoNotch/Services/CompletionFlashService.swift
NemoNotch/Services/CompletionToastQueue.swift
NemoNotch/Services/Hotkeys.swift
NemoNotch/Services/LauncherService.swift
NemoNotch/Services/PomodoroHistoryStore.swift
NemoNotch/Services/PomodoroStats.swift
NemoNotch/Services/PomodoroTimerService.swift
NemoNotch/Services/SystemService.swift
NemoNotch/Services/TaskStore.swift
NemoNotch/Settings/Pages/AlertsSettingsPage.swift
NemoNotch/Settings/Pages/AppListSettingsPage.swift
NemoNotch/Settings/Pages/HotkeysSettingsView.swift
NemoNotch/Settings/Pages/NotificationListSettingsPage.swift
NemoNotch/Settings/Pages/PomodoroSettingsView.swift
NemoNotch/Settings/SettingsSearchIndex.swift
NemoNotch/Settings/SettingsView.swift
NemoNotch/Tabs/LauncherTab.swift
NemoNotch/Tabs/PomodoroTab+ActiveBlock.swift
NemoNotch/Tabs/PomodoroTab+StatsPopover.swift
NemoNotch/Tabs/PomodoroTab+TodoList.swift
NemoNotch/Tabs/PomodoroTab.swift
NemoNotch/Tabs/SystemTab.swift
NemoNotchTests/BadgeDebounceTests.swift
NemoNotchTests/BadgeGroupingTests.swift
NemoNotchTests/PomodoroHistoryStoreTests.swift
NemoNotchTests/PomodoroStatsTests.swift
NemoNotchTests/PomodoroTimerServiceTests.swift
NemoNotchTests/TaskStoreTests.swift
NemoNotchTests/TodoTaskTests.swift
README.md
README_CN.md
docs/images/tab-launcher.png
docs/images/tab-pomodoro.png
docs/images/tab-system.png
scripts/uitest-screenshots.sh
```

## Findings

代码面无阻塞问题;要改的全是文档口径(含一处与本分支末提交自相矛盾的现在时断言)。

- AGENTS.md:23 —— 「现在提醒页只显示未授权脚注、无授权按钮」与末提交 09c5d2b 相反:AlertsSettingsPage.swift:72-82 已在等待提醒开启且未授权时渲染 PermissionCard(含 `.programmatic` 授权按钮);脚注 key `settings.waiting_reminder.no_permission` 也已从代码与目录删除。手册是现在时错述,下个读者会据此去"补"一个已存在的按钮。[P2]
- README.md:43 / README_CN.md:41 —— 「切换标签页默认 `⌥⌘1-5`」:Hotkeys.swift 现只剩 openOverview(⌥⌘1)/openAI(⌥⌘2),应改 `⌥⌘1-2`(或「⌥⌘1 / ⌥⌘2」)。[P2]
- AGENTS.md:120 —— 通知卡不变量(5)仍写「`showCompletionToast` 有那道门,通知卡不走它」,该方法已随番茄钟删除(CompletionFlashService.swift 原 156-172 行)。应删去括注或改指现存门禁(completionFlashEnabled 只门禁 AI/agent/日历的闪光入口)。[P3]
- scripts/uitest-screenshots.sh:62 —— `rm -f "$RECT_FILE"` 缩进 4 格,与循环体其余 2 格不一致(删注释时手滑)。[P3]
- NemoNotch/Settings/SettingsSearchIndex.swift:20-27 —— 授权卡挪到提醒页后,`permission.notification.title`(原随 .pomodoro 条目可搜)不再出现在任何页的索引里;建议并入 `.alerts` keys。非回归于主功能,属搜索可达性。[P3]
- docs/atoll-feature-gap.md:56,75 —— 竞品对比文档仍以现在时写「NemoNotch SystemTab 只有 CPU/内存/磁盘」「番茄钟 + TODO、App 启动器」。非手册,可选加一句"已于 2026-11-01 删除"。[P3]

### 已核对通过(证据梯级)

- 全量单测:`sh scripts/test.sh` 退出码 0,通过 590 · 失败 0(build/test.log)[4 级]。
- `sh scripts/doc-audit.sh` 退出 0;`sh scripts/check-arch.sh` 退出 0 [4 级]。
- 残留引用:`rg -i "pomodoro|番茄|launcher|quickstart|SystemService|SystemTab|LauncherService|AppItem|TaskStore|openSystem|topProcess"` 在 NemoNotch/ 与测试中零命中(仅 AlertsSettingsPage.swift:69 的说明注释)[2 级]。
- 持久化旧值:AppSettings.swift:203-213 `defaultTab` 经 `Tab(rawValue:)` 失败回落 .overview;`enabledTabs` compactMap 丢弃未知值并强插 .overview(全为旧值时得 {overview},不空集);SettingsView.swift:185/256 `SettingsPage(rawValue:) ?? .general` 处理残留 `settings.selectedPage = "pomodoro"/"appList"`;UITestMode.swift:13 `--tab=` 未知回落 overview。无 force unwrap [2 级,走失败路径]。
- 用户数据:diff 中无任何删除 ~/.NemoNotch 下 tasks/history 文件或 UserDefaults 键的代码 [2 级]。
- 本地化:对比 develop 目录,删除 90 个 key,脚本逐个在全部 Swift 源中查 `"key"` 字面引用——零命中;授权卡所用 `permission.notification.title/detail` 仍在目录 [4 级,脚本实跑]。
- Chin bar:Tab.chinPlacement 恒 .left,TabBarView rightTabs 为空时 ForEach 空渲染;设置/退出簇不受影响 [2 级]。
- 完成 toast 管线:CompletionSource 删 .pomodoro 后 switch 全部穷尽(编译通过);日历走 showCompletionFlash、通知卡走自身入口,均不依赖已删的 showCompletionToast [2 级 + 编译]。
- 环境注入:SettingsSceneRoot 仍注入 notificationPermission;NotificationListSettingsPage 改用 AppIconCache.icon(bundleID:)(CompletionToastView.swift:245 现存)替代 LauncherService [2 级 + 编译]。
- 授权卡只在用户打开等待提醒后才出现、点按钮才请求,符合"权限弹窗只在用户动作那一刻"原则 [2 级]。
- 测试未被削弱:BadgeGroupingTests 两处把 `.pomodoro(phase:)` 换成第二个不同 provider 的 AI 项(gemini,独立分组身份),5 组/4 组的 overflow/边界断言语义保留;BadgeDebounceTests 只删构造参数。其余删除的测试文件均只测已删代码 [2 级]。

### 教训候选

- AGENTS.md:23 —— 同一分支内先写手册、后改行为的提交顺序,会让手册断言被自己的后续提交推翻。判据:分支内任何改变行为的提交,提交前 `rg` 一遍本分支已改动的手册段落是否描述了该行为(可考虑 doc-audit 增一条:手册里出现的 Swift 符号名必须在源码中存在——能抓到 `showCompletionToast` 这类死符号)。
- 删特性时的"默认快捷键区间"类数字(⌥⌘1-5、"6 个 Tab")散落在 README 散文里,doc-audit 不覆盖;删 Tab 时应 rg `⌥⌘` 与 Tab 数字。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:新增/改动的测试有鉴别力吗?(被测代码全返回默认值还能过 = 没牙)
- [x] **证据纪律**:提交信息里的验证声明到第 4 级了吗(真跑过、有退出码/日志)?
- [x] **Swift 6 并发**:隔离标注正确?Sendable 边界清楚?回调线程假设实测过?
- [x] **最小改动**:每行可追溯到任务;没有顺手"改进"邻近代码
- [x] **错误路径**:失败会响(非零退出/日志),没有吞错、没有假绿
- [x] **坑总目录对照**:改到的区域在 AGENTS.md 有已知坑吗?对照过了吗?
- [x] **教训候选**:有「这段以后会再咬人」的新坑/新判据吗?没有写"无";有就记到 Findings 尾部「教训候选」小节(位置 file:line + 一句话判据)——收尾 reflect 会分流进 guardrail-backlog(能门禁化的)或 AGENTS.md 坑总目录
- [x] **文档同步**(复审通过):行为变了的话 AGENTS.md / README 跟上了吗?
- [x] **工作流机制清场**:本分支触及 hooks/scripts/CI——旧口径(措辞/路径/次序)全仓 grep 过了吗(AGENTS.md、docs/、注释)?证据贴 Findings。
## 评审方法提示(给评审会话)

在 worktree 里:`git diff 5ca1817034733ae877836224844c93a3cd2cd2d9...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。

## 复审(re-review,Reviewed-Head 87fd2af)

独立复审 09c5d2b..87fd2af 的修复提交,逐项核对:

- P2 AGENTS.md 授权按钮断言:已改为"挪到提醒页等待提醒栏,开关开且未授权显示 PermissionCard";与 AlertsSettingsPage.swift:73 实码一致 [2 级]。
- P2 README/README_CN 热键:改为 ⌥⌘1(总览)/⌥⌘2(AI),与 Hotkeys.swift:6-7 默认值一致;rg 无 ⌥⌘1-5 残留 [2 级]。
- P3 AGENTS.md showCompletionToast:已替换为 showNotificationToast 口径;仓内仅剩带日期的历史 spec 提及,属历史记录可接受 [2 级]。
- P3 uitest-screenshots.sh 缩进:已对齐为 2 空格 [2 级,cat -A]。
- P3 SettingsSearchIndex .alerts:已补 permission.notification.title/detail,与页面实用键一致 [2 级]。
- P3 docs/atoll-feature-gap.md:现在时断言改为带"已删"标注 [2 级]。
- 跑过:sh scripts/doc-audit.sh 退出码 0;sh scripts/test.sh --only SettingsSearchTests 退出码 0,build/test.log 全部 passed [4 级]。

结论:上轮全部 findings 已处理,无新增问题。
