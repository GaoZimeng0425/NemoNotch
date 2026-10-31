# Code Review — feature/toast-title-time

Reviewer: 独立评审子代理(Claude Opus,未参与开发;只读 diff + AGENTS.md + 真实 transcript 抽样)
Date: 2026-10-31
Reviewed-Head: 1bd76ee
Verdict: APPROVED
Scope:  12 files changed, 182 insertions(+), 44 deletions(-)

```
AGENTS.md
NemoNotch/Notch/CompletionToastView.swift
NemoNotch/Notch/CompletionToastWindow.swift
NemoNotch/Services/ClaudeCodeService.swift
NemoNotch/Services/CompletionFlashService.swift
NemoNotch/Services/CompletionToastQueue.swift
NemoNotch/Services/UserPrompt.swift
NemoNotchTests/CompletionToastClickTests.swift
NemoNotchTests/CompletionToastQueueTests.swift
NemoNotchTests/UserPromptTests.swift
README.md
README_CN.md
```

## Findings

证据完备度:标题过滤的判断基于本机 `~/.claude/projects` 最近 300 个 transcript 的 `type:"user"` 文本行抽样(脚本复跑,梯级 4);单测 `sh scripts/test.sh --only UserPromptTests,CompletionToastQueueTests,CompletionToastClickTests` 退出码 0、42 通过(梯级 4);相对时间方向用 `SystemFormatStyle.DateReference` 独立脚本实测输出「1分钟前/2小时前/昨天」(梯级 4)。未在运行中的 app 复现。

- **[P1] `NemoNotch/Services/UserPrompt.swift:8` + `NemoNotch/Services/ConversationParser.swift:183` — 同一症状类的高频漏网:`isMeta:true` 的注入 user 行不以前缀表里任何串开头,照样成为标题。** 实测抽样:`Base directory for this skill: …`(88 行,每次加载技能——Skill 工具或斜杠命令——都会在本轮末尾注入)、`Propose a new change - create …`/`Archive a completed change in …`/`Implement tasks from an OpenSp…`(斜杠命令展开,38/27/14 行)、`加载 \`octok-workflow\` 技能…`、`[1 prior /loop wakeup …]`、`[Usage limit reached …]`、`[Earlier usage-limit notes …]`。这些行都晚于用户输入,`UserPrompt.last` 取到的就是它们——加载过技能的每一轮卡片标题都会是「Base directory for this skill: /Users/…」,与用户报的「不知所云」同类。前缀黑名单在结构上追不上;transcript 自带权威信号 `isMeta`(上面所有行以及 `[Image: …]`、`<local-command-caveat>`、`<system-reminder>` 均为 isMeta)。建议:`parseUserMessage` 读 `json["isMeta"] as? Bool == true` 时不作为 typed 候选(带标志进 ChatMessage 或直接跳过——注意聊天视图是否要显示它们,择一),前缀表只留非 meta 的 `<task-notification>`/`<command-…>`/`<local-command-stdout>`/`[Request interrupted`/续写摘要;补一条带 isMeta 行的解析层测试(先红)。
- **[P2] `NemoNotch/Services/UserPrompt.swift:11` — `"[Image"` 前缀误杀真实输入。** 粘图提问在 transcript 里是非 meta 的 `[Image #1] 看看这里面的内容, …`/`[Image #3] dock 栏没有 icon`(抽样 12 行,本用户 UI 走查常用);被判注入后 `lastUserMessage` 停在**上一轮**的提问——卡片标题是错的那一轮,违背「标题是这一轮输入的内容」。注入形状是 `[Image: …`(带冒号,且是 isMeta),收窄为 `"[Image:"` 即可(P1 落地后这项连同前缀一起可删);可考虑剥掉开头的 `[Image #N]` 记号再取 80 字。补一条 `[Image #1] 文字` 判为 typed 的用例。
- [P3] `<` 一刀切的其余误杀:`<pasted_content id=…>` + 输入(25 行)与带参数斜杠命令 `<command-message>…<command-args>生成 3 个新 t…`(若干)也是用户这一轮真打的,同样回落上一轮提问。原样显示也不可读,回落是可接受折中,不阻塞;若顺手可从 `<command-args>` 取参数、跳过 `<pasted_content …>` 标签取其后文本。`[<div data-testid…` 形(agentation 元素引用,3 行)被 `[` 不受影响——前缀是 `[Image`,OK。
- [P3] `NemoNotch/Services/ClaudeCodeService.swift:224` — 注释「Parsing is incremental」写在发现路径(`parseFullResult`,新建 session)上,这里 `firstUserMessage` 必为 nil,守卫是 no-op;注释应只在 `parseConversation` 那处。增量路径(:515 起)first/last 语义正确:first 只在 nil 时写、last 仅在本块有 typed 行时前移,纯注入块不会抹掉上一轮提问——因果链对。
- [P3] `NemoNotch/Services/CompletionToastQueue.swift:58` — 等待堆里的卡被同一单元再次到达时重盖 `shownAt` 这条路径无测试:`mutate.sh` 把该行改成 `card.shownAt = card.shownAt.addingTimeInterval(0)`,`CompletionToastQueueTests` 仍绿(变异存活)。补一条「A 被挤进等待堆 → A 再到达 → shownAt == 新时间」。

无问题项(已核):
- 红提交 e95f41d 的桩完全复刻修复前语义(任何非空 user 文本),提交信息引真实红输出 `通过 2 · 失败 9`,与用例数吻合(6 个注入参数 + 3 个 first/last/nil 失败;空白参数与 typed 用例通过)——红的原因正确。两条 Claude 解析路径(发现 :224、增量 :515)都改走 `UserPrompt`。Gemini 路径未动(无此类注入,范围外,OK)。
- `CompletionFlashService.swift:80` `lastUserMessage ?? displayTitle`:opencode/zcode 无 lastUserMessage 时回落会话标题,行为与之前一致。
- 相对时间:`Text(.currentDate, format: .reference(to:…))` 系统驱动,无 Timer/TimelineView/`.animation`;方向实测为「…前」;`.fixedSize()` 的时间不截断、标题 `lineLimit(1)` 尾截断,卡片定宽 `cardWidth` 下 `Spacer(minLength:0)` 不会撑破。三种卡(AI/日历/通知)都套了同一 titleRow。
- shownAt 语义:到达/同单元再到达重盖、从等待堆递补保留原时间、pause/resume 不动——与字段注释一致,前两条有测试且有牙(递补/恢复用例断言字面 t0)。
- 文档:AGENTS.md / README.md / README_CN.md 同步描述了「标题=本轮输入」与「N 前」。

### 教训候选

- `NemoNotch/Services/UserPrompt.swift:8` — 判据:从 Claude transcript 里区分「用户输入 vs 注入」先用 transcript 自带的结构标志(`isMeta`、content block 类型),前缀黑名单只兜底;黑名单上线前要对真实 transcript 抽样跑一遍漏网/误杀统计(本次一个脚本就抓到 88 行漏网与 12 行误杀),只拿手挑样本写测试会两头都看不见。

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

在 worktree 里:`git diff 7e93644d5e313e55f0e5bc5431c8027376cae490...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。

## 复审(86c298c..1bd76ee)

Verdict: APPROVED。证据梯级 4(真跑过)。
- P1:`ConversationParser` 把 transcript 的 `isMeta` 带进 `ChatMessage.isMeta`,`UserPrompt.first/last` 先滤 isMeta。红提交 740f369 引真实红输出(失败 2:metaLinesAfterThePromptAreNotTheTitle、pastedImagePromptIsTyped),测试走 parseFullResult 真解析 JSONL(parser 级,非手造 ChatMessage)。
- P2:前缀收窄为 `[Image:`;`[Image #1] …` 判 typed、`[Image: original…]` 判注入,两向都有测试。
- P3:误置注释已删;新增 `waitingRearrivalStampsShownAt`。变异验证:`card.shownAt = now` → `.addingTimeInterval(0)`,`sh scripts/mutate.sh` 退出码 65,失败 1 通过 23(变异被抓);此前存活的变异现已有牙。
- `sh scripts/test.sh --only UserPromptTests,CompletionToastQueueTests` 退出码 0。AGENTS.md 同步了 isMeta 与 `[Image:` 口径。
- 披露:只复核了增量 diff 与上述测试,未重跑 300 份 transcript 抽样。
