# Code Review — feature/settings-native-search

Reviewer: independent review session (not the author)
Date: 2026-11-01
Reviewed-Head: 138d183
Verdict: APPROVED
Scope:  4 files changed, 17 insertions(+), 74 deletions(-)

```
NemoNotch/Resources/Localizable.xcstrings
NemoNotch/Settings/SettingsComponents.swift
NemoNotch/Settings/SettingsSearchModel.swift
NemoNotch/Settings/SettingsView.swift
```

## Findings

- 行为保留(证据梯级 2-3,读代码;测试 SettingsSearchTests 6/6 通过,退出码 0,build/test.log,但该测试只覆盖索引纯逻辑,不碰 UI):
  - 实时过滤:`SettingsView.swift:146-149` Binding 读写 `SettingsSearchModel.shared.query`,`matchedPages`(:234)在 body 里读它,Observation 依赖不变。
  - 回车跳首个命中页:`.onSubmit(of: .search)` (:153) 取代旧 TextField.onSubmit,逻辑原样。
  - 重开复位:`.onAppear` 置空(:128-130)未动。
  - 引用清理:`SettingsSidebarSearchBar` 与 `settings.search.clear` 全仓 rg 零残留;`settings.search.placeholder/results/no_matches` 仍在目录并仍被引用。
  - 挂载位置:`.searchable(placement: .sidebar)` 挂在侧栏列内容(pageList)上,是 NavigationSplitView 侧栏放置的正确位置;`.toolbar(removing:)` 与 `navigationSplitViewColumnWidth` 仍在同列,顺序在 searchable 之后无影响;自定义 `sidebarToggle` 在 detail 列未动。
- [P3] 视觉/工具栏未验证:无法截图。唯一未证实的风险是 .searchable 的 .sidebar 放置在该 `Window` scene + `toolbar(removing: .sidebarToggle)` + 玻璃背景下是否引入工具栏抖动或额外 NSToolbar 项,以及顶部间距是否真的消除(用户投诉的核心)。合并后需肉眼确认:起 app 开设置窗,看搜索框与「通用」间距,折叠/展开侧栏看有无 » 溢出闪。
- [P3] 侧栏折叠时搜索框随侧栏隐藏,过滤状态不可见(旧版同样,非回归)。
- 教训候选:无(只有"视觉修复需人眼验收"这条一次性事项,不可门禁化)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:新增/改动的测试有鉴别力吗?(被测代码全返回默认值还能过 = 没牙)
- [x] **证据纪律**:提交信息里的验证声明到第 4 级了吗(真跑过、有退出码/日志)?
- [x] **Swift 6 并发**:隔离标注正确?Sendable 边界清楚?回调线程假设实测过?
- [x] **最小改动**:每行可追溯到任务;没有顺手"改进"邻近代码
- [x] **错误路径**:失败会响(非零退出/日志),没有吞错、没有假绿
- [x] **坑总目录对照**:改到的区域在 AGENTS.md 有已知坑吗?对照过了吗?
- [x] **教训候选**:有「这段以后会再咬人」的新坑/新判据吗?没有写"无";有就记到 Findings 尾部「教训候选」小节(位置 file:line + 一句话判据)——收尾 reflect 会分流进 guardrail-backlog(能门禁化的)或 AGENTS.md 坑总目录
- [x] **文档同步**:行为变了的话 AGENTS.md / README 跟上了吗?

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 7d31e0d2879f7e484876ddd1fd9098afcd70ddda...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
