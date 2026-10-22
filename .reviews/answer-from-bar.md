# Code Review — feature/answer-from-bar

Reviewer: ZCode 独立评审会话(未参与开发;judge ≠ author)
Date: 2026-10-22
Verdict: APPROVED
Scope:  14 files changed, 459 insertions(+), 37 deletions(-)

```
NemoNotch/Models/AIProvider.swift
NemoNotch/Models/HookResponse.swift
NemoNotch/Models/SessionPhase.swift
NemoNotch/Notch/EdgeBar/EdgeBarCard.swift
NemoNotch/Notch/EdgeBar/EdgeBarController.swift
NemoNotch/Resources/Localizable.xcstrings
NemoNotch/Services/AICLIMonitorService.swift
NemoNotch/Services/ClaudeCodeService.swift
NemoNotch/Services/HookServer.swift
NemoNotchTests/AskAnswerTests.swift
AGENTS.md / README.md / README_CN.md / .reviews/answer-from-bar.md
```

## Findings

无 P1。两条 P2 建议随合并(或紧随其后)补一个 commit 修掉;均不阻塞。

- **[P2] 重复问题文本时 answers 键碰撞,静默发出错误答案** — `NemoNotch/Models/SessionPhase.swift:143-159` + `SessionPhase.swift:269-280`。`InteractivePrompt.parse` 对重复文本的问题**不**去重(评审任务里"parse 对重复文本弃整题返回 nil"是 evlat 的行为,本 port 没带过来);`AskAnswer.answers` 以 `question.text` 为键,两题同文本时后一题的答案覆盖前一题——两题收到同一个答案,用户对第一题的勾选被静默丢弃。机制出处 evlat 把重复文本判为"不可按键作答"直接弃整个 ask(`evlat/Sources/EvlatCore/AskQuestion.swift:34-35`:`!questions.contains(where: { $0.text == text }) else { return nil }`,回落终端作答)。建议:`AskAnswer.answers` 遇 prompt 内重复文本返回 nil(卡片回落 Deny/jump,与"缺题不发"同一保守语义)。形状罕见(AskUserQuestion 由模型生成,文本无唯一性约束),故 P2 非 P1。
- **[P2] 两处代码注释仍写着已被本次推翻的"协议级不可行"** — `NemoNotch/Models/SessionPhase.swift:104-106`("The hook protocol can only answer allow/deny — a choice is the user's to make in the CLI — so this exists for display, not for answering")与 `NemoNotch/Notch/EdgeBar/EdgeBarCardModel.swift:7-10`("choices are the user's to make in the CLI, so the card shows them and jumps, it does not pretend Allow/Deny answer them")。AGENTS.md 新写的教训行("『协议不可行』的断言先查兄弟项目实装再下")恰恰点名的这类残留,代码里还留着两份反例。注释级、零行为影响,但与分支自己的立论直接矛盾。
- **[P3] 作答点击路径(经 ScrollView)无 level-5 验证记录** — `NemoNotch/Notch/EdgeBar/EdgeBarCard.swift:344-368`。选项行是该面板**第一批位于 SwiftUI ScrollView 内的几何路由按钮**;既有 allow/deny/jump 全在 ScrollView 外。evlat 的 DetailCard 在同一架构(onButtonFrame 几何路由)下同样把 optionRow 放进 ScrollView(`evlat/Sources/EvlatApp/UI/DetailCard.swift:519-531`,生产验证过),先例强;但本 port 提交信息对在跑 app 里的点击无任何验证声明。合并前补一次真机点击或在提交信息补 level-5 声明。
- **[P3] 换题瞬间点击旧帧的亚帧竞态,后果有界** — `EdgeBarController.swift:806-815`(press 延迟 0.12s 后 `perform` 重读当下 phase)+ `EdgeBarCard.swift:355-360`。toolUseId 更换的一拍里 buttonRects 尚未随重渲染更新:单题单选路径 `immediateReply` 可能按**新** prompt 的 `choices[旧索引]` 发出错误标签;多选路径只留下越界 stray key——`AskAnswer.answers` 只读有效题的 picks,越界键被忽略(**不会卡死 Send**,与 [0:[7]] 测试一致),下次 `syncAskPicks` 即清。窗口 ~1 帧、需旧 ask 超时+新权限+点击同在 120ms 内,可不修。
- **[P3] `AIProvider` 扩展的默认空实现当前不可达** — `NemoNotch/Models/AIProvider.swift:20-24`。`AICLIMonitorService.respondToAsk` 按 source 显式路由,非 claude 只记日志,默认实现无人调用(全仓 grep 证实)。防御性死代码,可接受。
- **[P3] wire 测试断到结构级而非字节级** — `NemoNotchTests/AskAnswerTests.swift:56-79`。round-trip 解析断言了全部语义载荷(hookEventName/behavior/updatedInput 原文全量随行/answers),对比 `HookResponseTests` 对 decision 的字节级断言,answer 路径的 sortedKeys 确定性未被钉住。评审人已用变异验证护栏有牙(见下),可选补一条"两次编码字节相等"断言。

### 已查证无问题的重点(评审任务清单逐项)

- **wire 同构**:`jsonData()` 的 `.answer` 分支与 evlat `PermissionHook.body` 的 `.answer` 分支(`evlat/.../PermissionHook.swift:178-187`)逐字段同构,与本项目 Codable `.decision` 形状(`hookSpecificOutput.hookEventName/decision.behavior`)同构;两路径统一 `sortedKeys + withoutEscapingSlashes`。`.ack/.decision` 由 `sortedKeys` 改为加 `withoutEscapingSlashes`:全部既有载荷(allow/deny/timeout/"session ended"/"no session id"/"PermissionRequest")无 `/`,字节不变——`HookResponseTests` 的字节级断言仍绿。
- **`encode(to:)` 对 `.answer` 抛错不可达**:全仓仅 `HookServer.sendJSON` 编码 HookResponse,已改走 `jsonData()`(grep 证实);测试文件对 `.ack/.decision` 走 Codable、从不碰 `.answer`。抛错是有效的绊线。
- **updatedInput 全量随行 / 坏 JSON**:真实路径下 `ctx.toolInput` 必然可解析(`interactivePrompt` 本身由解析它得出,`SessionPhase.swift:194-201`),`?? [:]` 与 `?? "{}"` 均为与 evlat 相同姿态的死防御,有测试覆盖。
- **`immediateReply` 的 question==0 硬编码自洽**:前置 `questions.count == 1` 使 0 成为唯一合法题号;越界 press 落入 pick 分支成 stray key,被 `answers()` 忽略,无害。
- **状态机**:`askPicks` 在 deselect/closeBar 清、`syncAskPicks` 按 toolUseId 重置(换题/答完/卡撤都清);press 延迟期间卡消失(deselect 清 pressedButton)则 perform 按 guard 落空——正确;`ClaudeProvider.respondToAsk` 无 pending 连接时仍转 processing,与既有 `respondToPermission` 逐字一致,非回归。
- **卡高**:问题区 ScrollView 上限 168,`EdgeBarMetrics.cardTop`(:222-240)把整卡夹在画布内;最坏 4 题(≈400-450pt)在任何现役屏高内放得下。
- **本地化**:`Text(cond ? "a" : "b")` 三元字面量解析到 LocalizedStringKey 重载(swiftc 重载消歧实验证实)——pick_one/pick_any 正常取键;`edge_bar.answer_hint` 已删且无悬挂引用(grep);目录 canonical(xcstrings.py check 过)。
- **历史对照**:AGENTS.md:91、README.md:57、README_CN.md:55 三处新表述与代码逐点一致(allow+updatedInput.answers、updatedInput 整包替换、草稿不齐不发、仅 claude、单题即答/多选打勾+发送);"自由文本原样通过"只陈述 wire 语义,UI 未提供自由文本入口(evlat 有"Other…"行,本 port 刻意简化)——不算矛盾。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:有牙。评审人独立变异 `updated["answers"] = answers` → `[:]`(`sh scripts/mutate.sh NemoNotch/Models/HookResponse.swift 'updated["answers"] = answers' 'updated["answers"] = [:]' --only AskAnswerTests`):**2 例红(退出码 65),文件已恢复**——wire 护栏有牙;`[0:[7]]` 越界例、"x, z" 选项序例、immediateReply 越界例均钉具体输出。作者另验证过 immediateReply→nil 变异。
- [x] **证据纪律**:部分。提交信息引 evlat 实测(借得 level 5)但未对本 port 的在跑 app 交互作任何声明(见 P3-1)。评审人重跑全部门禁(level 4,退出码见下)。
- [x] **Swift 6 并发**:HookServer/ClaudeProvider/EdgeBarController 均 @MainActor(类级),无新 Sendable 边界;`press` 的 `MainActor.assumeIsolated` hop 为既有模式。
- [x] **最小改动**:`sendJSON` 重构对既有载荷字节不变;`multiSelect` 带默认值的 init 零调用点扰动;未顺手改邻近代码。
- [x] **错误路径**:`jsonData()` 抛错 → sendJSON catch → 500 + error 日志(响亮);无 pending 连接静默与既有 respondToPermission 一致。
- [x] **坑总目录对照**:Edge Bar 三坑未踩——定位用真布局无 `.offset`、无 opacity 隐藏、无 repeatForever;hover 动画与既有 cardButton 同款(瞬态);拖拽帧纪律未触碰。
- [x] **文档同步**:AGENTS/README×2 与代码一致;代码注释残留两处矛盾(P2,上面第二条)。

## 验证记录(评审人执行,worktree 内)

- `sh scripts/test.sh --only AskAnswerTests` → **7/7 通过,退出码 0**(日志 build/test.log)
- 变异验证(上)→ 变异被抓住,退出码 65,原文件恢复;事后 `git status` 干净
- `python3 scripts/xcstrings.py check` → canonical,退出码 0
- `sh scripts/doc-audit.sh` → 通过,退出码 0
- `sh scripts/lint.sh` → 通过,退出码 0(仅既有文件的既有 warning,均不在本分支改动行)
