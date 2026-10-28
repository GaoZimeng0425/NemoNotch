# Code Review — feature/process-routing

Reviewer: 独立评审子代理(zcode 会话,judge ≠ author,未参与开发)
Date: 2026-10-28
Reviewed-Head: ad1cedc
Verdict: APPROVED
Scope:  2 files changed, 219 insertions(+), 25 deletions(-)

```
.zcode/workflows/implement-with-review.dwf.ts
AGENTS.md
```

## Findings

- **[P2] `.zcode/workflows/implement-with-review.dwf.ts:242-243`(对照 :77-86 接口声明)— 免闸合取式不消费 `audit.recommendation`,挑战者的「建议动作」可在直通路径被静默丢弃。**
  问题:`DiagnosisAudit.recommendation` 声明了 `"proceed" | "needs-user" | "not-a-bug" | "no-fix"` 四值(:85),是挑战者对「该不该修」的唯一表态;但 `autoProceed = audit.sound && survey.reproduced && audit.mechanicalFix && confirmed !== undefined`(:242-243)不含它。四个字段语义正交:`sound` 审证据链、`mechanicalFix` 审修法形状、`recommendation` 审去留——「证据链成立、修法确实机械,但这是拍板行为/产品取舍,建议 not-a-bug / needs-user」是自洽且可达的输出,此时工作流免闸直通建环+实现,把挑战者唯一携带「别修」表态的字段扔在 floor 上。该字段只在 abort 结论文本(:267)与拍板闸提示里出现——恰是已有人工介入的路径。对照评审问的「免闸是否可能被误触发」:`reproduced=false` 不可能直通(`survey.reproduced` 在合取式内,已核 :243),但 `recommendation ∈ {not-a-bug, needs-user, no-fix}` 可以。
  建议:合取式加一项 `audit.recommendation === "proceed"`(一行),任何非 proceed 建议一律路由到拍板闸。

- **[P3] `AGENTS.md:230` + `.zcode/workflows/implement-with-review.dwf.ts:5`(description)— 免闸口径手册比脚本松两个合取项。**
  手册与 description 写「复现确凿且修法机械免闸直通」,脚本实际还要求 `audit.sound` 与「至少一个探针 confirmed」(:242-243)。方向安全(脚本更严:复现确凿但探针全证伪/挑战者判不 sound 时仍会开闸问人),但按本仓「代码、手册同一提交对齐」的口径属漂移——读者会以为复现+机械必直通。建议手册/description 补齐(「且挑战者判 sound、有探针证实」),或注明系简写。

- **[P3] `.zcode/workflows/implement-with-review.dwf.ts:287` — 拍板闸空 note 时,给建环者的提示谎报「免闸直通」。**
  `拍板闸补充:${gateNote || "(免闸直通:复现确凿+修法机械)"}` 的回退文案在「走了拍板闸、操作者 continue 未带 note」时同样触发——那是人工放行,不是免闸;与同一条提示里权威的 `复现状态` 行(:288,可能=未复现)自相矛盾。同一路径下 `bugDiagnosis`(:294)在「无确认探针+空 note」时根因字段为空串。缓解:复现状态行明确且建环者 plan 首部要求由它驱动。建议区分闸来源(记一个布尔),回退文案改「(拍板闸放行,无补充)」,并对空根因 guard。

- **[P3] `.zcode/workflows/implement-with-review.dwf.ts:320-322` — 合流评审的 bug 专项镜头只在脚本里,AGENTS 与 description 均未记载。**
  symptom 路径给评审员加的「核验失败测试红转绿、修复与根因因果对应、无越出根因的顺手改动」是 bug 修复质量的关键校验面,但 AGENTS.md:230 只写到「合流 feature 开发段」,metadata description(:2-6)同样未提。属「脚本做了手册没写」。建议 AGENTS 该句或 description 补一小句;若拍板「合流段行为全量继承、不另行记载」,在 Finding 回复中说明即可。

- **[P3] `.zcode/workflows/implement-with-review.dwf.ts:290-293` — 建环者输出零校验即覆盖四参。**
  scaffold 返回的 worktree/planPath/branch 直接顶替入口参数,无存在性断言;建环者写错路径时,失败要到实现者(读不到 plan 升级停下)或评审员阶段才显形,浪费整轮。feature 入口四参由主对话保证,这里全信一个子代理。建议覆盖后加廉价检查(planPath 可读、worktree 目录存在),不成立即响亮 return。

- **[P3] `.zcode/workflows/implement-with-review.dwf.ts:268` — abort 结论承诺「重跑会快」缺乏机制支撑。**
  重跑(CreateWorkflow saved)起全新 run:复现侦探只被要求读 AGENTS 坑总目录(:210-212),拿不到上一 run 的探针记录(computed 名 agent 也不复用缓存);「探针结论已记录」只对旧 run 的 journal 成立。除非操作者手动把旧结论贴进 symptom。建议删掉「重跑会快」或改为「重跑时把本次诊断结论附进 symptom 描述」。

### 教训候选

- `.zcode/workflows/implement-with-review.dwf.ts:85 vs :242-243` — 判据:**接口里声明为「建议动作/裁决」的字段,必须出现在消费它该在的决策合取式里;声明即消费,否则就是给人看的摆设**。适用于所有未来 gate 类脚本。
- `AGENTS.md:230` vs 脚本合取式 — 手册句子描述门禁布尔条件时,与脚本的合取项数容易漂移;本次是脚本更严(安全方向),反向漂移就是门禁松动。可考虑进 guardrail-backlog:对「免闸/门禁条件」类口径做成 doc-audit 式成对断言的成本先评估(自然语言句子难机判,可能只值得 review checklist 一条)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A——无测试改动(工作流 TS + 文档,无 Swift 变更,affected-tests 不适用)。
- [x] **证据纪律**:提交信息不含验证声明(纯描述性)。本记录的声明附真实命令+退出码于下方「评审证据」。
- [x] **Swift 6 并发**:N/A——无 Swift 改动。
- [x] **最小改动**:逐 hunk 核过(diff 全量读):三 persona 常量字节级未动(sed 块提取 develop/分支两版 diff,退出码 0);评审循环、合流、报告逻辑对 feature 路径(symptom="")行为等价——所有新增插值条件(bugDiagnosis 前缀 :381/:396/:411、镜头 :320-322)在空串时退化为旧文案;参数缺校验从旧版 String(undefined) 垃圾串改为响亮早退(:194-202),是改进非回归。
- [x] **错误路径**:缺参早退响亮(:194-202);拍板闸 abort 路径响亮且如实(:262-279);artifact.file catch 沿用旧版(log 兜底,前次评审已记 P3,未恶化)。P2/P3 见上。
- [x] **坑总目录对照**:新 persona 对照过手册——手挑类名假绿(implementer/scaffold 均钉 affected-tests.sh)、日志时间戳本地时(:154)、观测不成律(:158)、五级梯级(:165 与手册梯级一一对应)、影响面测试、judge≠author(诊断挑战者 :169 未参与侦察探针)。未发现矛盾。
- [x] **教训候选**:见上小节。
- [x] **文档同步**:AGENTS.md 与脚本同一提交改(本次改动本体);README 不适用(纯开发流程,无用户可见功能变化)。

## 评审证据(命令 + 真实退出码)

- `git -C <worktree> diff develop...feature/process-routing` — 两文件全量 diff 逐 hunk 审毕(退出码 0)。
- `sh scripts/doc-audit.sh`(worktree 内)— **退出码 0**,六条断言全绿;AGENTS.md 新句未破坏成对断言,新引用路径 `.zcode/skills/brainstorming/SKILL.md` 实际存在(ls 验证)。
- `sh scripts/review.sh process-routing` — **退出码 0**,生成本模板。
- 三 persona 字节级比对(develop vs 分支,sed 块提取 + diff)— **退出码 0,无差异**。
- 门禁问「reproduced=false 会不会直通」— 证据 `.dwf.ts:243`:`survey.reproduced` 在 autoProceed 合取式内,不可能。
- facade 交叉核对(dynamic-workflows SKILL.md §15/§16,梯级 2):`hole<T>(name, prompt)` 签名一致、洞名「根因拍板闸」与全部 phase 标记不重名、不在 fan-out 回调内、`args` typeof 收窄是文档钦定模式、agent 字面名无重复、每个 phase 含 ask。**完备度披露:未实际提交 CreateWorkflow 编译(评审不应启动 run),编译级正确性止步 facade 逐项比对,非梯级 4。**
- 陈旧口径 grep:`rg "implement-with-review"` 全仓 — 其余命中为 plan 文档(泛引用,兼容双入口)与 .reviews 历史记录(证据链,不应改写),无四参旧口径残留。

## 第 2 轮(bc4f4c5 → ad1cedc,单提交追加,无 rebase)

**Verdict: APPROVED** — P2 修复核实,五条 P3 均已修到主范围;残余两条 P3 级可选项(下述),无新引入 P1/P2。

### 逐条核验(对照第 1 轮 Findings)

- **P2(autoProceed 不消费 recommendation)— 已修。** 新合取式(dwf.ts:243-253 区域)`audit.sound && survey.reproduced && audit.mechanicalFix && audit.recommendation === "proceed" && confirmed !== undefined`,上方注释说明否决表态不能被静默丢弃。任何非 proceed 建议均路由拍板闸。
- **P3(免闸口径漂移)— 已修。** metadata description 与 AGENTS.md:230 均改五合取口径,五项与脚本合取式逐项对应:复现确凿↔`survey.reproduced`、证据链审计成立↔`audit.sound`、修法机械↔`audit.mechanicalFix`、有确认探针↔`confirmed`、挑战者建议 proceed↔`audit.recommendation === "proceed"`。零漂移。
- **P3(谎报免闸直通)— 已修(主范围)。** 回退文案按 `autoProceed` 分支:免闸写五合取说明,闸门放行写「(拍板闸放行,无补充说明)」。**残余 P3(接受/缓修)**:`bugDiagnosis` 的 `根因:${confirmed ? confirmed.summary : gateNote}` 在「闸门 continue + 空 note + 无确认探针」的边角仍为空串——报告文案小疵,已被新加的建环守卫与提示里的复现状态行兜住,不阻合并。
- **P3(bug 专项镜头未记载)— 已修。** description 与 AGENTS 均补「合流评审带 bug 专项镜头(失败测试必须由红转绿、修复与根因因果对应)」。镜头第三子句「无越出根因的顺手改动」仍只在脚本里——摘要级记载,可接受。
- **P3(建环输出零校验)— 已修(主范围)。** scaffold 返回后、覆盖四参前加缺参守卫:任一为空即带诊断 findings 响亮中止,不进实现段;return 形状与其余路径一致,守卫内引用的 probes/survey/confirmed 均在作用域。**残余 P3(接受)**:守卫查空串不查存在性(错而非空的路径仍过守卫)——失败时实现者按纪律在读不到 plan 处升级停下,有界。
- **P3(「重跑会快」假声明)— 已修。** 改为如实口径「重跑本工作流从诊断段重新开始(无跨 run 记忆)」。

### 新问题扫描

- 修复增量(delta 逐 hunk 读)只触及合取式、两处文案、abort 结论与建环守卫;**三个共享 persona 常量与 agent 字面名零改动**(grep 计数 0)。
- 守卫位置正确:在 `task/worktree/branch/planPath = scaffold.*` 赋值之前;`if (symptom)` 块内作用域完整。
- 多行合取式与新增注释为合法 TS;无新 facade API。

### 第 2 轮证据

- `git diff bc4f4c5..ad1cedc` — 两文件增量逐 hunk 核毕(退出码 0)。
- `git merge-base --is-ancestor bc4f4c5 ad1cedc` — 通过(单提交追加,无 rebase;`git log bc4f4c5..ad1cedc` 仅 1 提交)。
- `sh scripts/doc-audit.sh` — **退出码 0**(新 AGENTS 句仍全绿)。
- `git status --porcelain` — 仅 `?? .reviews/process-routing.md`(本记录),工作树无其他改动。
