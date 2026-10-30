# Code Review — feature/notification-toast-default-off

Reviewer: independent review session (not the author)
Date: 2026-10-30
Reviewed-Head: d3f5eed
Verdict: APPROVED
Scope:  5 files changed, 9 insertions(+), 9 deletions(-)

```
AGENTS.md
NemoNotch/Models/AppSettings.swift
NemoNotchTests/AppSettingsNotificationToastTests.swift
README.md
README_CN.md
```

## Findings

- 无阻断项。
- NemoNotch/Models/AppSettings.swift:289 默认值 `?? true` → `?? false` 正确;仅此一处读取默认(:132 属性无初始值),消费点 NotificationToastService.swift:45 以 guard 门禁,设置页 Toggle 绑定同一属性。[已核]
- NemoNotchTests/AppSettingsNotificationToastTests.swift:28 默认断言 false:若默认仍为 true 必红,有鉴别力。:38-41 持久化测试改为写 true/读 true(非默认值),若不持久化会回落 false 而变红——比旧版(写 false,与新默认相同)更有牙,翻转是必要的。[已核]
- 同文件 :11-21 withCleanKeys 保存两键原值、defer 恢复(nil 经 set(_:forKey:) 等价移除),确认还原。
- 文档:AGENTS.md(默认关+屏幕共享照常显示,用户拍板)、README.md(Off by default)、README_CN.md(默认关闭)三处一致。屏幕共享决定只记在 AGENTS.md,README 未提,可接受(非用户可见功能说明)。[P3,不阻断]
- 证据:`sh scripts/test.sh --only AppSettingsNotificationToastTests` 退出码 0,build/test.log 两个用例均 passed(梯级 4)。输入完备度:未做变异验证、未在运行 app 中复现。
- 教训候选:无。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [ ] **判别剃刀**:新增/改动的测试有鉴别力吗?(被测代码全返回默认值还能过 = 没牙)
- [ ] **证据纪律**:提交信息里的验证声明到第 4 级了吗(真跑过、有退出码/日志)?
- [ ] **Swift 6 并发**:隔离标注正确?Sendable 边界清楚?回调线程假设实测过?
- [ ] **最小改动**:每行可追溯到任务;没有顺手"改进"邻近代码
- [ ] **错误路径**:失败会响(非零退出/日志),没有吞错、没有假绿
- [ ] **坑总目录对照**:改到的区域在 AGENTS.md 有已知坑吗?对照过了吗?
- [ ] **教训候选**:有「这段以后会再咬人」的新坑/新判据吗?没有写"无";有就记到 Findings 尾部「教训候选」小节(位置 file:line + 一句话判据)——收尾 reflect 会分流进 guardrail-backlog(能门禁化的)或 AGENTS.md 坑总目录
- [ ] **文档同步**:行为变了的话 AGENTS.md / README 跟上了吗?

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 37fa6ba2c929f767afbb5a6c3444abbc6a0ffb9d...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
