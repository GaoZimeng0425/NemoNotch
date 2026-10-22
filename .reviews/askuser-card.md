# Code Review — feature/askuser-card

Reviewer: 独立评审子代理(zcode 会话,未参与开发)
Date: 2026-10-22
Verdict: APPROVED
Scope:  9 files changed, 294 insertions(+), 30 deletions(-)

```
AGENTS.md
NemoNotch/Models/SessionPhase.swift
NemoNotch/Notch/EdgeBar/EdgeBarCard.swift
NemoNotch/Notch/EdgeBar/EdgeBarCardModel.swift
NemoNotch/Resources/Localizable.xcstrings
NemoNotchTests/EdgeBarCardTests.swift
NemoNotchTests/InteractivePromptTests.swift
README.md
README_CN.md
```

## Findings

无 P1/P2。三条 P3(均为边缘情形或可读性,不阻塞合并):

- **[P3] 零选项的多选卡失去 Deny/Allow** — `NemoNotch/Models/SessionPhase.swift:141-149`:`parse` 只对 question 文本设防,`options` 缺失/全空时仍保留 `Question(text:, choices:[])`,`asksToChoose` 因此为真(`EdgeBarCardModel.swift:20-25`),畸形 interactive 载荷(如 `{"questions":[{"question":"Q?"}]}`)会渲染成"只有去选择、无 Allow/Deny"的卡。实际 CLI 对 AskUserQuestion 校验 2–4 选项,且用户仍可在终端作答 / 120s fail-close,故仅边缘。若要更稳,可让 `asksToChoose` 要求 `questions.contains { !$0.choices.isEmpty }`。
- **[P3] `.jump` 帧上报出现第二来源,分支互换的理论竞态** — `NemoNotch/Notch/EdgeBar/EdgeBarCard.swift:364` 与 `:402`(goButton)在互斥分支各报 `.jump`;若 phase 在一次 store 突变内直接从"带 prompt 的 approval"换到"不带 prompt 的 approval"(正常路径经 processing,按钮先全卸),新 goButton 的 onGeometryChange 与旧 cardButton(.jump) 的 onDisappear 顺序未定义,可能短暂留下 stale/nil 的 `buttonRects[.jump]`(`EdgeBarController.swift:586-588`)。与既有 deny/allow 换卡同一危害等级、自愈(下次帧变即修正),不阻塞。
- **[P3] 混合 &&/|| 无括号,靠优先级承载布局语义** — `NemoNotch/Notch/EdgeBar/EdgeBarCard.swift:142`:`row.hasHost && !goStandsDown || !Self.isSection(content) ? …`。已核对 Swift 优先级(&& 先于 || 先于三元),四种 hasHost × goStandsDown × section 组合语义全部正确(多选卡 section 收底、bottom padding 归零、由 sectionGround 自带 14pt 兜底);但加一对括号可免后人误读。

## 重点项核查结论(审查方要求逐项)

1. **parse 健壮性:通过。** `questions`/`question`/`options`/`description` 类型不符全部经条件降级安全落 nil(测试覆盖 `{"questions":"oops"}`、`[["options":[]]]`、`["other":"x"]`、非 JSON);顶层兜底仅在 `question` 键存在且为非空 String 时生效,且两个调用点(`displayInput`/`interactivePrompt`)都先过 `isInteractiveTool` 门,不会吞非 interactive 工具的键。`truncate(prompt.summary, limit: 160)` 交互正确:String.prefix 按字素截断,多字节安全;非 JSON 的 interactive 输入回落 `formattedToolInput` → ""(与改前一致,无回归)。
2. **计算属性重解析:正确性与性能均无问题。** `interactivePrompt`/`displayInput` 是不可变 `toolInput` 的纯函数,同输入恒产相等值(合成 Equatable 数组逐项比),无 Equatable 抖动。关键:真正参与相等比较的路径**不含 prompt** —— `refresh` 的 `next != content` 与 `.animation(value: bar.content)` 走 `EdgeBarModel.Content` → `EdgeBarRow.phase` → `PermissionContext ==`(只比 toolUseId,`SessionPhase.swift:229-231`);卡片 `.animation(value: row)` 亦然。`Body` 不进任何 animation(value:)。每次卡片 body 重算(hover/press/row 变化)付出 2 次 JSONSerialization + 2 次 parse,载荷 ≤2KB、µs 级,TimelineView 每分钟只刷新自身闭包不触发父 body。可接受。
3. **布局回归:通过。** 运算符优先级语义正确(见 P3-3);多选无 host 时 `answer_hint` 确实渲染(`EdgeBarCard.swift:365-369`,键已在目录);`cardButton(.jump)` 与底部 goButton 互斥共存(goStandsDown 同时门控挂载与 bottom padding),同时刻至多一个 `.jump` rect(见 P3-2)。
4. **xcstrings:通过。** 本评审实跑 `python3 scripts/xcstrings.py check` → `canonical`(exit 0),410 keys,插入序保留(answer/answer_hint 位于 edge_bar.jump 前)。
5. **测试鉴别力:通过(变异独立复验)。** 6 例均为具体 JSON → 字面输出(问题文本、label 数组、summary 字符串、Body 相等、垃圾输入 == nil)。本评审亲自跑两条变异:`parse → return nil` 致 5 例红(exit 65);`asksToChoose → return false` 致 1 例红(exit 65);文件均恢复,`git status` 仅剩本评审文件。守卫有牙。
6. **最小改动:通过。** 9 文件全部可追溯到两项投诉;AIChatTab 零改动,其 `displayInput` 读取点(`AIChatTab+Sessions.swift:107,429`)免费获得单行摘要;`EdgeBarCardTests.swift` 仅 1 行适配新枚举参量;拒绝键提亮(fill 0.10→0.14 + 白描边)严格限于 cardButton 静音支(只有 Deny 用到)。
7. **AGENTS.md 对照:通过。** 无 offset/opacity 隐藏、无新 transition/repeatForever、无 NSView;动态文本全 `Text(verbatim:)`、字面键走目录;AGENTS.md Edge Bar 节 + README/README_CN 同一提交更新,符合"事实变了代码/手册同一提交改";`scripts/doc-audit.sh` exit 0。协议边界断言(PermissionRequest 只能回 allow/deny)与官方 hook 文档一致,display-only + jump 是正确推论。

## 评审证据(第 4 级,全部本评审亲自跑)

- `sh scripts/test.sh` 全量:**494 通过 / 0 失败,退出码 0**(日志 build/test.log)。
- `sh scripts/test.sh --only InteractivePromptTests`:6/6;`--only EdgeBarCardTests`:9/9,均退出码 0。
- `sh scripts/mutate.sh` 两条变异均红(exit 0 = 守卫有牙),原文件恢复。
- `python3 scripts/xcstrings.py check` → canonical;`sh scripts/doc-audit.sh` exit 0;`sh scripts/lint.sh` exit 0(余警均在未触碰文件:SystemService/HookServer/NowPlayingCLI,系既有)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:6 例全部具体输入→字面输出;两条变异独立复验变红,有牙。
- [x] **证据纪律**:本评审亲跑测试/变异/lint/doc-audit,退出码与日志如上。
- [x] **Swift 6 并发**:无新并发面——纯值类型 + SwiftUI 视图改动,无隔离/Sendable 新边界。N/A 之外无风险。
- [x] **最小改动**:见重点项 6;无顺手改动。
- [x] **错误路径**:parse 一切失败落 nil(已测);无吞错新路径。
- [x] **坑总目录对照**:Edge Bar 三坑(offset/transition/repeatForever)与 SwiftUI 渲染坑均未触碰;见重点项 7。
- [x] **文档同步**:AGENTS.md / README / README_CN 同提交更新,doc-audit 过。
