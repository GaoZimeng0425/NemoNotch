# Code Review — feature/calendar-toast-detail

Reviewer: independent review session (not the author)
Date: 2026-10-30
Reviewed-Head: 7f61f7f
Verdict: APPROVED
Scope:  9 files changed, 150 insertions(+), 11 deletions(-)

```
AGENTS.md
NemoNotch/Notch/CompletionToastView.swift
NemoNotch/Services/CalendarDueMonitor.swift
NemoNotch/Services/CalendarToastCard.swift
NemoNotch/Services/CompletionDetector.swift
NemoNotchTests/CalendarToastCardTests.swift
README.md
README_CN.md
docs/superpowers/specs/2026-10-30-calendar-toast-detail-design.md
```

## Findings

- 链接打开路径正确:`CalendarToastCard.swift:24` 快照 `tabLink` → `CompletionToastClick.action`(CompletionToastLayout.swift:89)有 jump 即 `.jump`、无链接即 `.dismiss`、× 恒 `.dismiss` → `AppActivator.activate` 先 `NSWorkspace.open(url)`(AppActivator.swift:31)。hostPID/bundleId 为 nil,打开失败时无回落,仅记 warn,可接受。[通过]
- 时区:`timeLine` 用注入的 `timeZone`(默认 `.current`)+ POSIX locale + 固定 `HH:mm`,测试以 UTC 固定,不依赖机器时区。[通过] 跨午夜事件只显 HH:mm,可接受。
- `CalendarToastCard.swift:36` 地点判 URL 用 `hasPrefix("http")`:无 scheme 的 `meet.google.com/abc` 会被当作地点显示(链接行同时也显示,重复);以 "http" 开头的真实地名(如 "Httpbin Cafe")会被吞。[P3]
- `meetingURL`(CalendarEvent.swift:36)的 NSDataDetector 会把 notes 里的邮箱识别成 `mailto:`,卡片会显示 "mailto:" 链接行、点击打开邮件撰写。与 OverviewTab 既有行为一致,非本分支引入,但卡片点击会把它放大。[P3,既有]
- 测试鉴别力:`timeAndLocation`/`meetingLinkIsShownAndClickable`/`genericLinkShowsHost` 以具体输入断言字面输出,返回默认值会失败。缺口:Teams/Meet 标签分支与"仅空白地点"无测试(P3);`CompletionToastClick` 对带 calendar 链接 item 的 jump 由既有点击决策测试覆盖。真跑:`sh scripts/test.sh --only CalendarToastCardTests` 退出码 0,日志 build/test.log 5 个用例全 passed。
- 文档:AGENTS.md 完成闪光节、README.md、README_CN.md 均已同步,与代码一致(复用 `meetingURL`、快照进 `CompletionJump.tabLink`、无链接只关卡)。
- 最小改动:`CalendarDueMonitor` 仅替换 item 构造;`CompletionItem.calendar` 两个 init 都已初始化。

### 教训候选

- 无(`mailto:` 经 meetingURL 泄入"会议链接"属既有问题,可在日后碰 meetingURL 时限定 http/https scheme)。

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

在 worktree 里:`git diff 7f278f94d5d1f47558bfa929e481a9f75839fce0...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
