# Code Review — feature/toast-per-session

Reviewer: independent review subagent (Claude, fresh context; did not author this branch)
Date: 2026-10-28
Reviewed-Head: b363c48
Verdict: APPROVED
Scope:  5 files changed, 57 insertions(+), 7 deletions(-)

```
AGENTS.md
NemoNotch/Services/CompletionDetector.swift
NemoNotch/Services/CompletionToastQueue.swift
NemoNotchTests/CompletionDetectorTests.swift
NemoNotchTests/CompletionToastQueueTests.swift
```

## Findings

- 结论:所有产生 toast 的路径都过 `CompletionToastQueue.add`(CompletionFlashService.swift:207/153/185),去重键已换成 `toastKey`(CompletionToastQueue.swift:40)。AI 会话候选 key=`ai:<session.id>`(CompletionFlashService.swift:63)、agent=`agent:<agent.id>`(:79),detector 把 key 带到 item(CompletionDetector.swift:146)——同项目同 app / 跨 app 的不同会话各成一卡,满足用户要求。驱逐按 deadline(CompletionToastQueue.swift:47-50)、闪光节流只管辉光(CompletionFlashService.swift:200-208),都不按名合并。无会话来源(番茄钟 :153、日历 CalendarDueMonitor.swift:101-108、UI-test 种子 :185-189)key=nil → 退回按名,符合「有会话才按会话」。
- CompletionToastQueue.swift:41 + CompletionDetector.swift:184:队列按 toastKey 命中后仍交给 `CompletionFlashNames.merge`,而 merge 内部按 **name** 匹配并取 `[0]`。同一会话两次完成之间 name 变了(name = `projectFolder ?? displayTitle`,CompletionFlashService.swift:64;cwd 变化或 cwd 缺失时首条消息晚到)→ merge 走 append 分支,`[0]` 返回旧 item 原样:计时刷新了,但 name/tool/tokens/duration 全是旧值且无声。分支前两处键一致,本分支引入不一致。罕见,不阻塞;建议让 merge 按 toastKey 匹配或在队列内直接做字段合并 [P3] — **已修(b363c48)**:merge 按 toastKey 匹配,命中即以新 item 整体替换(含 name/source),nil 富字段回落旧值(CompletionDetector.swift:185-194);新测 `sameSessionRenamed`(CompletionToastQueueTests.swift:70-81)
- CompletionDetector.swift:178 merge 的文档「skipping duplicate names」与多元素 append 语义现在只剩 queue 一个调用点且只用 `[0]`,属半死代码;连同上一条一起收拾即可 [P3] — **已修(b363c48)**:文档改为按 toastKey、一键一项;多元素语义仍被 CompletionDetectorTests:82 等直接测试使用,保留合理
- CalendarDueMonitor.swift:101-108:同标题的两个日历事件同时到期仍并成一卡(无 key → 按名)。不属本次「会话」范围,分支前即如此,仅记录 [P3] — 协调者确认保留为既有行为
- NemoNotchTests/CompletionToastQueueTests.swift:28 旧测试名「same name refreshes…」现实际守的是无 key 的按名回退路径,名字可更准确;不影响鉴别力 [P3] — **已修(b363c48)**:改名为「without a session key, same name refreshes…」

### 复审 b363c48(f354a46..HEAD:CompletionDetector.swift merge 改写 + 一条新测 + 一处测试改名)

- 新发现:无。merge 改写后语义:同 key → 新值整体胜出、nil 富字段继承旧值;不同 key → 追加。现有按名回退(无 key)的 merge 测试(CompletionDetectorTests:82/160/172、CompletionPathTests:51/54)均仍通过。
- `sh scripts/test.sh --only CompletionToastQueueTests,CompletionDetectorTests,CompletionPathTests` → exit 0,通过 32 · 失败 0(与 b363c48 提交信息一致)。
- `sh scripts/mutate.sh NemoNotch/Services/CompletionDetector.swift 'result.firstIndex(where: { $0.toastKey == item.toastKey })' 'result.firstIndex(where: { $0.name == item.name })' --only CompletionToastQueueTests` → exit 0(变异被抓:失败 1 / 通过 11)。
- `sh scripts/mutate.sh NemoNotch/Services/CompletionDetector.swift 'merged.tool = item.tool ?? older.tool' 'merged.tool = item.tool' --only CompletionToastQueueTests` → exit 0(变异被抓:失败 1 / 通过 11)。两次均自动恢复。
- 端口:复审开始与结束时 hook-sender.sh / hermes-hook-sender.sh 均为 `# port: 45831`;文件 mtime 19:37:26(协调者恢复,早于本轮首个测试宿主 19:38:00),本轮 5 个测试宿主日志无任何 HookServer/插件写入。

### 首轮运行证据(f354a46,梯级 4)

- `sh scripts/test.sh --only CompletionToastQueueTests,CompletionDetectorTests,CompletionPathTests` → exit 0,通过 31 · 失败 0(与 f354a46 提交信息所述一致)。
- `sh scripts/mutate.sh NemoNotch/Services/CompletionToastQueue.swift '$0.item.toastKey == item.toastKey' '$0.item.name == item.name' --only CompletionToastQueueTests` → exit 0(变异被抓:失败 1 / 通过 10)。
- `sh scripts/mutate.sh NemoNotch/Services/CompletionDetector.swift 'item.key = candidate.key' '_ = candidate.key' --only CompletionDetectorTests` → exit 0(变异被抓:失败 1 / 通过 12)。两次均自动恢复,`git status` 仅剩本评审记录。
- red 提交 21540cf 信息引用了真实失败输出(exit 65,keys 只有 ["ai:claude-1"]);red 提交含 `key` 字段是让测试能编译的最小接缝,可接受。

### 环境事件(非本分支造成,须告知用户)

- 评审开始时 `~/.NemoNotch/hooks/hook-sender.sh` 为 `# port: 45831`;19:34:34 被改写为 `# port: 45832`(hermes-hook-sender.sh、opencode 插件同时被改写),而真实 app(pid 61310)仍只监听 45831 → CLI hook 事件当时发往死端口(协调者已于 19:37:26 恢复为 45831)。日志 19:34:34.755「Hook server failed on 45831 … listening on 127.0.0.1:45832 / Wrote opencode plugin (port 45832)」来自**并发跑测的 `.worktree/claude-quota-snapshot` 测试宿主**(其 test.log mtime 19:34:35;该分支不含 56c5f39 守卫,`merge-base --is-ancestor` = NO_GUARD)。本分支测试宿主 19:34:38 启动,无 HookServer/插件写入日志;两次 mutate 后文件 mtime 仍为 19:34:34。

### 教训候选

- CompletionToastQueue.swift:40-41:「外层按键 A 查找、内层 helper 按键 B 合并再取 `[0]`」会让键不一致时静默丢更新——换去重键时,所有下游合并 helper 的匹配键要一起换(可加一条测试:同 key 不同 name 的二次完成必须刷新字段)。
- 宿主守卫只在合进 develop 之后的分支生效:旧 worktree(如 claude-quota-snapshot)跑单测仍会改写共享 hook 配置。可门禁化方向:`scripts/test.sh` 跑前后比对 `~/.NemoNotch/hooks/*.sh` 的 port 行,变了即响亮报错,不依赖被测代码自带守卫。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:新增/改动的测试有鉴别力吗?(被测代码全返回默认值还能过 = 没牙)— 两个变异均被杀,有牙
- [x] **证据纪律**:提交信息里的验证声明到第 4 级了吗(真跑过、有退出码/日志)?— red exit 65 / green exit 0 均引用,复跑一致
- [x] **Swift 6 并发**:隔离标注正确?Sendable 边界清楚?回调线程假设实测过?— N/A:纯值类型改动,无隔离变化
- [x] **最小改动**:每行可追溯到任务;没有顺手"改进"邻近代码— 是
- [x] **错误路径**:失败会响(非零退出/日志),没有吞错、没有假绿— 见 P3:merge `[0]` 在键不一致时静默保留旧值
- [x] **坑总目录对照**:改到的区域在 AGENTS.md 有已知坑吗?对照过了吗?— 完成闪光/Toast 节已更新;番茄钟 toast-only 不动节流不变
- [x] **教训候选**:有「这段以后会再咬人」的新坑/新判据吗?没有写"无";有就记到 Findings 尾部「教训候选」小节(位置 file:line + 一句话判据)——收尾 reflect 会分流进 guardrail-backlog(能门禁化的)或 AGENTS.md 坑总目录— 见 Findings 尾部
- [x] **文档同步**:行为变了的话 AGENTS.md / README 跟上了吗?— AGENTS.md 已改;README/README_CN 早已写「每个会话/Agent 一张」

## 评审方法提示(给评审会话)

在 worktree 里:`git diff b48eae7899e51d12b51de33a2a5daa0a7633c9d4...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
