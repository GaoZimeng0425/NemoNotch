# Code Review — feature/capsule-fixes

Reviewer: independent review subagent (Claude Opus 5.5, fresh context, did not author this branch)
Date: 2026-10-27
Reviewed-Head: 7ad2367
Verdict: APPROVED
Scope:  8 files changed, 299 insertions(+), 91 deletions(-)

```
AGENTS.md
NemoNotch/Notch/NotchCapsuleView.swift
NemoNotch/Notch/NotchView.swift
NemoNotch/Services/BluetoothService.swift
NemoNotch/Services/HUDService.swift
NemoNotch/Services/PowerSourceEdge.swift
NemoNotchTests/NotchCapsuleTests.swift
NemoNotchTests/PowerSourceEdgeTests.swift
```

## Findings

无 P1 / P2。

- [P3] NemoNotch/Notch/NotchCapsuleView.swift:78-111 — 弹开现在**硬依赖** `onGeometryChange` 至少回调一次(`measuredContentWidth != nil` 才开);旧代码测不到宽时至少还按刘海宽开、内容照常淡入,新代码会整只胶囊停在刘海宽且内容永远 opacity 0。同款模式在仓内已有先例(AIStatusFABView / closedContentSize),初值回调可信,但 7ad2367 的提交信息里没有任何运行证据(无单测覆盖视图时序,也没写真机复现)——视图侧改动停在证据梯第 2 级。建议合并后按「插拔电源 / 连断耳机,看胶囊从刘海宽弹到内容宽、连续两次事件只换内容不叠影」真机过一遍。
- [P3] NemoNotch/Services/PowerSourceEdge.swift:15,52 — `PowerSourceChange.levelChanged` 与 `.reading` 生产代码未读(HUDService.swift:296-318 用的是本地 `reading`,里程碑判定用 `capacity % 10`);只被测试读。无害,属于为可测而留的冗余字段。
- [P3] 行为面变化(有意、已入手册):无内置电池的机器(台式机 + UPS)不再弹充电胶囊/电池 HUD;多源时只看内置电池。HUDService.swift:294 `trackedReading` 返回 nil 时整段静默返回。与 AGENTS.md 蓝牙/IOKit 节新增条目一致。

核对过的点(非问题):
- NotchView.swift:180-189 单挂载位:`if let capsule` 分支结构位置不变,充电↔蓝牙切换时 `NotchCapsuleView` 的 @State 保留,内容靠 `.id(capsule.id)` + `.transition(.opacity)` 换;动画事务来自 NotchView.swift:225-226 既有的 `.animation(value:)`。
- HUDService.swift readBattery:首读种基线、相同读数不报、10% 里程碑与「胶囊关时边沿才弹药丸」逻辑与旧实现等价;`takeUnretainedValue` 的 Get-rule 注释保留。
- c5f761e 先落失败测试并引用真实失败输出(exit 65,upsOnly/upsListedFirst 失败),03ce415 引用转绿输出——符合「修 bug 先落失败测试」。

评审员自跑(证据梯第 4 级):
- `sh scripts/test.sh --only NotchCapsuleTests,PowerSourceEdgeTests` → exit 0,14 通过 0 失败
- `sh scripts/mutate.sh NemoNotch/Services/PowerSourceEdge.swift '<内置电池类型过滤>' '.first' --only PowerSourceEdgeTests` → 变异被抓(测试 exit 65,3 失败),文件已恢复
- `sh scripts/mutate.sh NemoNotch/Notch/NotchCapsuleView.swift 'if let charging {' 'if let charging, bluetooth == nil {' --only NotchCapsuleTests` → 变异被抓(测试 exit 65,1 失败),文件已恢复
- `sh scripts/check-arch.sh` → exit 0;`sh scripts/doc-audit.sh` → exit 0
- 未做真机复现(第 5 级):评审员不跑 build.sh 部署。

### 教训候选

- NotchCapsuleView.swift:78 — 「动画起跑等两个条件到齐」的门(appeared ∧ measured)把一次测量缺失从「视觉瞬跳」升级成「永不显示」;判据:凡把动画门控在异步测量上,要么有兜底(超时/首帧后按默认宽开),要么在手册写明依赖 onGeometryChange 初值回调。

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

在 worktree 里:`git diff b0e3e0c831cd250c2ced58c2ca1260520aa0351d...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
