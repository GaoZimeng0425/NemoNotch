# Code Review — feature/zcode-open-tool-demote

Reviewer: zcode-judge(独立评审子代理,未参与开发;bf3ca48 初审 + e4600d2 delta 补审)
Date: 2026-11-01
Reviewed-Head: e4600d2
Verdict: APPROVED
Scope:  4 files changed, 175 insertions(+), 2 deletions(-)

```
NemoNotch/Services/ZcodeProvider.swift
NemoNotchTests/ZcodeProviderTests.swift
docs/superpowers/plans/2026-11-01-zcode-open-tool-demote.md
.reviews/zcode-open-tool-demote.md
```

## Findings(三条 P3 及处置记录)

- P3 `NemoNotch/Services/ZcodeProvider.swift:74-80` — UserPromptSubmit 不复位 `isPreToolUse`,「PreToolUse 后事件链断裂(Post/Failure/Stop 皆未达)→ 续新 prompt 且新 turn 无工具无 Stop」的会话永久跳过静默降级(徽章转满 30 分钟、currentTool 残留)。**处置:不采纳复位修法,评审认同**——复位收益(窄场景显示瑕疵 30→5 分钟)小于其风险:zcode 是 Claude 形状,若存在 turn 中排队消息且 UserPromptSubmit hook 在排队时即发,复位会落在长工具执行窗口内,重新打开本分支刚关死的假「完成」toast 门;无实测证据排除该窗口(观测不成律),选低危害侧。理由已在 plan「刻意不修」段落留档。
- P3 `docs/superpowers/plans/2026-11-01-zcode-open-tool-demote.md:8` — 第 5 项裸框会被 plan 全勾门禁拦。**处置:已勾**(e4600d2,grep 裸框计数 0)。
- P3 `NemoNotchTests/ZcodeProviderTests.swift:85` — PostToolUseFailure 关闭工具后的对称降级路径无测试。**处置:已采纳**(e4600d2 新增 `failedToolThenSilenceStillDemotes`,变异验证有牙:`case "PostToolUseFailure":` → 死标签,套件 2 红,mutate.sh exit 0)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:有牙,双向 + 失败路径三向变异亲验:`if session.isPreToolUse` → `if false`(守卫失效)openToolCallIsNotDemotedBySilence 红;→ `if true`(修过头)closedToolSessionStillDemotesAfterSilence 红;`case "PostToolUseFailure":` → 死标签 failedToolThenSilenceStillDemotes 红(连带既有 failure 测试)。red→green 重放:checkout c227c19 跑套件,openToolCallIsNotDemotedBySilence() failed、其余过。断言面在 store 落库内容(status/currentTool),非发起方返回值。
- [x] **证据纪律**:第 4 级。提交信息引用红/绿输出与变异结果,本评审全部亲跑复核:bf3ca48 套件 6/6(exit 0)、e4600d2 affected-tests.sh 7/7(exit 0)、red 重放红、三次变异被杀、lint/check-arch/doc-audit 均 exit 0。30 分钟回收不造假 toast 的关键前提经代码证实(CompletionDetector.swift:164-187,消失单元 dropped not reported)。
- [x] **Swift 6 并发**:类 @MainActor,函数继承隔离;private→internal + `now` 注入未引入 Sendable 边界;timer 调用点(ZcodeProvider.swift:185)走默认参数,生产行为不变。delta 未触碰 Swift 生产源码。
- [x] **最小改动**:守卫 10 行 + 测试缝 + 三个守卫测试,每行可追溯到任务;demote mutate 里既有 `isPreToolUse = false` 冗余行未顺手删(正确);opencode 同款逻辑刻意不动并留档。
- [x] **错误路径**:无吞错路径新增;跳过降级有注释说明取舍(死于工具中段 → 30 分钟静默消失,非误报完成)。
- [x] **坑总目录对照**:AGENTS.md zcode 节「不发 SessionEnd、靠 stale 超时回收」与改动一致;守卫不触碰 routeEvent 归属、`sess_` 前缀兜底、token 回填节流等已知坑区。
- [x] **教训候选**:见下方小节。
- [x] **文档同步**:AGENTS.md zcode 节现有表述仍准确;新语义(open-tool 不降级)与 P3-1 处置均已在 plan 留档,reflect 阶段决定是否进坑总目录。

### 教训候选

- `NemoNotch/Services/ZcodeProvider.swift:196-226` — 「静默 = 完成」的兜底假设在存在不可见执行段(subagent、长工具调用,期间 hook 零事件)时必然误报;凡新增「靠超时推断完成」的逻辑先问:有没有合法的长时间无事件执行段。
- `NemoNotch/Models/AIProvider.swift:52` — 跨事件布尔标志的复位收紧要先排除「复位时机可能落在合法执行窗口内」(本例:排队 prompt 与长工具执行的交叠窗口无实测证据排除);没有该窗口不存在的证据,就在非对称风险下选低危害侧(自愈瑕疵 < 误报回归)。
