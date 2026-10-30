# Code Review — feature/notification-fda-detect

Reviewer: independent review session (non-author)
Date: 2026-10-30
Reviewed-Head: d8a705e
Verdict: APPROVED
Scope:  2 files changed, 49 insertions(+), 5 deletions(-)

```
NemoNotch/Services/NotificationCenterReader.swift
NemoNotchTests/NotificationCenterReaderTests.swift
```

## Findings

- 因果链(梯级 4):症状消息「没有将文件“db”保存到文件夹“db2”中的权限」是 NSFileWriteNoPermissionError(513)的本地化文案;旧 catch 只认 fileReadNoPermission,513 落入 `.unavailable(localizedDescription)`,与日志原文一致。修法 NotificationCenterReader.swift:68-85 `classifyOpenFailure` 把 513 与 POSIX EPERM/EACCES 归 `.noAccess`,直接对应症状。
- 红提交 988a55f:测试调真函数、断言字面 `.noAccess`/`.unavailable("database not found")`,有鉴别力(默认返回值过不了);提交信息引了 red 输出(2 失败,exit 65)。绿侧我真跑 `sh scripts/test.sh --only NotificationCenterReaderTests`:exit 0,4 用例全过(build/test.log)。红侧未重放,采信提交信息。
- [P3] NotificationCenterReader.swift:77 新增 `.fileNoSuchFile` 属顺手扩展(请求外),无害,无测试覆盖该分支。
- [P3] 测试只覆盖分类函数,probe 到 `classifyOpenFailure` 的接线(:27-28)无测试(真权限,AGENTS.md 允许跳过)。
- 证据完备度:未在真机无 FDA 环境复现,判断基于日志文案 + 单测。

### 教训候选
- NotificationCenterReader.swift:68:TCC 拒绝在 macOS 27 的 Cocoa 错误码不稳定(读操作报 write 类码)——判据:凡把 TCC 拒绝映射到「需授权」UI 的分类,按「任一权限类码 + POSIX EPERM/EACCES」匹配,别按单一码;可记入坑总目录「Keychain / 权限 / TCC」节。

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

在 worktree 里:`git diff b065a4ba07f020a4f6a11ad4c05c39d68f9f4b7a...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
