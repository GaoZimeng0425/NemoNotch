# Plan: zcode 静默降级不弹假「完成」——未闭合工具调用不降级

- [x] 0. 前置:根因确认状态与证据基线(只读,本任务不改代码)
- [x] 1. 失败测试:未闭合工具调用的会话在 5 分钟静默后**不**被降级(先红)
- [x] 2. 修复:`cleanupStaleSessions` 跳过 `isPreToolUse == true` 的会话(含 `now` 注入缝)
- [x] 3. 守卫有牙:`scripts/mutate.sh` 验证新测试
- [x] 4. 影响面测试 + lint 全绿
- [x] 5. 独立评审 + feat-done 合并部署

## 0. 根因确认(首部声明)

**根因已经用户拍板确认(2026-11-01 对话,「修,不应该 5 分钟」),非未确认推断。**

症状:zcode 的完成 toast 两头误报——「弹了完成但其实还在跑」与「跑完了不弹/迟到 5 分钟」。

证据链(梯级标注):

1. (④ 活体探针)2026-11-01 13:44-13:45:spawn 的 subagent 跑 67s、内部 3 次工具调用,期间主会话 hook 事件为 **0**——只有 Agent 工具自己的 Pre/Post 夹住窗口。subagent 内部干活对 hook 完全不可见。
2. (③ 日志关联)2026-10-31 16:28:13 `PreToolUse` → 16:32:58/16:33:58 两次静默降级(各触发一次完成 toast)→ 16:36:58 `PostToolUse` 才回来:一个 ~9 分钟的工具调用期间被误判完成两次。
3. (② 代码路径)`ZcodeProvider.cleanupStaleSessions`(`silentDemoteThreshold = 300`):任何非 idle/ended 会话静默 5 分钟即 `processing→idle`;`CompletionFlashService`(isActive == working)把该边沿当完成 → toast。分不清「真完了」和「正在安静地干活」。
4. (③ 日志)终端 CLI 会话的 Stop 正常到达(本诊断会话 turn 结束 9s 内到);不发 Stop 的是老格式 `session_<hex>` 会话(GUI/长命,另案给 zcode 提需求)。

**修法(用户已拍板方向)**:有未闭合工具调用(`PreToolUse` 已发、`PostToolUse`/`PostToolUseFailure`/`Stop` 未回,即 `isPreToolUse == true`)的会话**不参与**静默降级,交给既有 30 分钟 stale 回收——CLI 死于工具中段时静默消失,而不是被宣告「完成」。Stop 正常到达的路径完全不受影响。

**刻意不修(留档)**:
- 长纯生成间隙(最后一个 PostToolUse 后模型长时间思考 >5min)理论可误报,日志无实证,不动。
- opencode provider 有同款 5 分钟降级逻辑,无证据表型,不动。
- `session_<hex>` 老格式 id 不匹配 `sess_` 前缀兜底(`AICLIMonitorService.routeEvent`):真实事件大多带 `cli_source` 标签,store 已在时 default 分支救回;单独议题,不混入本分支。
- 评审 P3:`UserPromptSubmit` 不复位 `isPreToolUse`(事件链断裂残留 → 徽章最多多转至 30 分钟回收,自愈)。**刻意不采纳复位修法**:zcode 是 Claude 形状,若支持 turn 中排队消息,复位会在「排队 prompt 落在长工具执行中」时重新打开假「完成」toast 的门——宁留显示瑕疵,不冒误报回归。

## 1. 失败测试(首任务)

`NemoNotchTests/ZcodeProviderTests.swift` 新增:

- `openToolCallIsNotDemotedBySilence`:UserPromptSubmit → PreToolUse(Bash) → 注入 `now = +400s` 跑 cleanup → 断言 `status == .working` 且 `currentTool == "Bash"`。修复前此断言为红(现状会降级成 idle)。
- `closedToolSessionStillDemotesAfterSilence`:UserPromptSubmit → PreToolUse → PostToolUse → `now = +400s` cleanup → 断言 `status == .idle`(守住 GUI 无 Stop 会话的迟到通知路径,防修过头)。

需要最小测试缝:`cleanupStaleSessions` 从 `private func cleanupStaleSessions()` 改为 `func cleanupStaleSessions(now: Date = Date())`(internal,`@testable` 可见;timer 调用点不变)。

提交:测试单独成 commit,提交信息引用真实红输出(red→green 可重放)。

## 2. 修复

`ZcodeProvider.cleanupStaleSessions` 降级循环内、两个既有 `continue` 守卫之后新增:

```swift
// An open tool call (PreToolUse seen, its PostToolUse not yet back) means
// the CLI is still executing: builds, test runs and subagents regularly run
// past 5 min with zero hook events in between (subagents fire no hooks at
// all — 2026-11-01 probe). Demoting here fires a false "completed" toast
// mid-work. Leave these to the stale reaper below: a dead CLI disappears
// silently at 30 min instead of being announced as completed.
if session.isPreToolUse {
    continue
}
```

不新增阈值常量、不动 30 分钟回收循环、不动 opencode。

## 3. 变异验证

`sh scripts/mutate.sh NemoNotch/Services/ZcodeProvider.swift "if session.isPreToolUse {" "if false {" --only ZcodeProviderTests` → 必须红(exit 0=守卫有牙)。若变异注入语法不适配,选等价单行变异(如 `if session.isPreToolUse { continue }` 整段替换为空),原则:让「跳过守卫失效」,套件必须变红。

## 4. 验证

- worktree 内 `sh scripts/affected-tests.sh`(映射为空回落全量;禁手挑 --only 当门禁)
- `sh scripts/lint.sh`
- 全绿后进评审。

## 5. 评审与合并

- 独立评审(`sh scripts/review.sh <name>` 模板,未参与本实现的会话填写,Verdict: APPROVED + Reviewed-Head)。
- 评审 prompt 只给 diff + AGENTS.md + worktree 只读权,不带本 plan。
- `git feat-done zcode-open-tool-demote`(主检出执行)。
- 部署后 reflect:教训候选「静默=完成的兜底假设遇到不可见执行段必误报」,评估是否值得进 AGENTS 坑总目录。
