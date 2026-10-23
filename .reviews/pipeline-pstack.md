# Code Review — feature/pipeline-pstack

Reviewer: ZCode 独立评审子代理(未参与本分支开发;judge ≠ author)
Date: 2026-10-23
Verdict: APPROVED
Scope:  90 files changed, 11327 insertions(+), 2 deletions(-)
分支 head(评审时):2b3f434(判决新鲜度锚点;head 变了本 Verdict 不再描述补丁)

```
.gitignore
.zcode/skills/PROVENANCE.md
.zcode/skills/brainstorming/SKILL.md
.zcode/skills/brainstorming/builder-check-prompt.md
.zcode/skills/brainstorming/scripts/frame-template.html
.zcode/skills/brainstorming/scripts/helper.js
.zcode/skills/brainstorming/scripts/server.cjs
.zcode/skills/brainstorming/scripts/start-server.sh
.zcode/skills/brainstorming/scripts/stop-server.sh
.zcode/skills/brainstorming/visual-companion.md
.zcode/skills/diagnosing-superpowers/SKILL.md
.zcode/skills/diagnosing-superpowers/prompts/analyst-common.md
.zcode/skills/diagnosing-superpowers/prompts/cost-and-time.md
.zcode/skills/diagnosing-superpowers/prompts/plan-adherence.md
.zcode/skills/diagnosing-superpowers/prompts/quality-evidence.md
.zcode/skills/diagnosing-superpowers/prompts/repeated-work.md
.zcode/skills/diagnosing-superpowers/prompts/request-conflicts.md
.zcode/skills/diagnosing-superpowers/prompts/scrub-audit.md
.zcode/skills/diagnosing-superpowers/prompts/scrub.md
.zcode/skills/diagnosing-superpowers/prompts/similar-session.md
.zcode/skills/diagnosing-superpowers/prompts/skill-timeline.md
.zcode/skills/diagnosing-superpowers/prompts/stumbles.md
.zcode/skills/diagnosing-superpowers/references/context-safety.md
.zcode/skills/diagnosing-superpowers/references/github-issues.md
.zcode/skills/diagnosing-superpowers/references/redaction-policy.md
.zcode/skills/diagnosing-superpowers/references/session-discovery.md
.zcode/skills/diagnosing-superpowers/templates/bundle-README.md
.zcode/skills/diagnosing-superpowers/templates/case.md
.zcode/skills/diagnosing-superpowers/templates/issue.md
.zcode/skills/diagnosing-superpowers/templates/report.md
.zcode/skills/dispatching-parallel-agents/SKILL.md
.zcode/skills/executing-plans/SKILL.md
.zcode/skills/executing-plans/scripts/task-done
.zcode/skills/executing-plans/scripts/task-start
.zcode/skills/finishing-a-development-branch/SKILL.md
.zcode/skills/recall-nemonotch/SKILL.md
.zcode/skills/receiving-code-review/SKILL.md
.zcode/skills/requesting-code-review/SKILL.md
.zcode/skills/requesting-code-review/code-reviewer.md
.zcode/skills/subagent-driven-development/SKILL.md
.zcode/skills/subagent-driven-development/implementer-prompt.md
.zcode/skills/subagent-driven-development/re-review-prompt.md
.zcode/skills/subagent-driven-development/references/batching.md
.zcode/skills/subagent-driven-development/references/cannot-verify.md
.zcode/skills/subagent-driven-development/references/final-review.md
.zcode/skills/subagent-driven-development/references/fix-loop.md
.zcode/skills/subagent-driven-development/references/handling-reports.md
.zcode/skills/subagent-driven-development/references/preflight.md
.zcode/skills/subagent-driven-development/references/resuming.md
.zcode/skills/subagent-driven-development/scripts/review-package
.zcode/skills/subagent-driven-development/scripts/sdd-workspace
.zcode/skills/subagent-driven-development/scripts/task-brief
.zcode/skills/subagent-driven-development/task-reviewer-prompt.md
.zcode/skills/superpowers-LICENSE
.zcode/skills/systematic-debugging/CREATION-LOG.md
.zcode/skills/systematic-debugging/SKILL.md
.zcode/skills/systematic-debugging/condition-based-waiting-example.ts
.zcode/skills/systematic-debugging/condition-based-waiting.md
.zcode/skills/systematic-debugging/defense-in-depth.md
.zcode/skills/systematic-debugging/find-polluter.sh
.zcode/skills/systematic-debugging/root-cause-tracing.md
.zcode/skills/systematic-debugging/test-academic.md
.zcode/skills/systematic-debugging/test-pressure-1.md
.zcode/skills/systematic-debugging/test-pressure-2.md
.zcode/skills/systematic-debugging/test-pressure-3.md
.zcode/skills/test-driven-development/SKILL.md
.zcode/skills/test-driven-development/writing-good-tests.md
.zcode/skills/using-git-worktrees/SKILL.md
.zcode/skills/using-superpowers/SKILL.md
.zcode/skills/using-superpowers/references/antigravity-tools.md
.zcode/skills/using-superpowers/references/claude-code-tools.md
.zcode/skills/using-superpowers/references/codex-tools.md
.zcode/skills/using-superpowers/references/gemini-tools.md
.zcode/skills/using-superpowers/references/hermes-tools.md
.zcode/skills/using-superpowers/references/muse-tools.md
.zcode/skills/using-superpowers/references/pi-tools.md
.zcode/skills/verification-before-completion/SKILL.md
.zcode/skills/writing-plans/SKILL.md
.zcode/skills/writing-skills/SKILL.md
.zcode/skills/writing-skills/references/CLAUDE_MD_TESTING.md
.zcode/skills/writing-skills/references/anthropic-best-practices.md
.zcode/skills/writing-skills/references/bulletproofing.md
.zcode/skills/writing-skills/references/discovery.md
.zcode/skills/writing-skills/references/flowcharts.md
.zcode/skills/writing-skills/references/graphviz-conventions.dot
.zcode/skills/writing-skills/references/persuasion-principles.md
.zcode/skills/writing-skills/references/testing-skills-with-subagents.md
.zcode/skills/writing-skills/render-graphs.js
.zcode/workflows/implement-with-review.dwf.ts
AGENTS.md
```

## Findings

**P2**

- **[P2] `.zcode/workflows/implement-with-review.dwf.ts:127,133` + `scripts/review.sh:41-49` — 回流环"核验上一轮意见"对两席均不可达,且 review.sh 会抹掉中间轮的 .reviews 记录。**
  round>1 的 ask 只说"重点核验上一轮意见是否修到位",但不携带上一轮 findings;两席每轮都是全新 context(`评审员-第${round}轮`,每轮新 agent),凭空无法知道"上一轮意见"是什么。唯一可能的上轮意见载体 `.reviews/<branch>.md` 恰好在下一轮开始时被摧毁:REVIEWER_PERSONA(:88)指示"先跑 `sh scripts/review.sh <branch>` 生成模板",而 review.sh 只保护已填 `Verdict: APPROVED` 的记录(`grep -q '^Verdict: APPROVED'`,:41-44),上一轮 REJECTED/CHANGES_NEEDED 的记录会被 `cat > "$note"`(:49)整文件模板重生成——上轮 findings 在下一轮评审读到之前就没了。
  后果:①回流环每轮退化为全量重审,设计声称的"核验修复+回归检查"名存实亡(findings 确实回流给了实现者 :155,实现者能修;失效的只是复审侧的针对性核验);②`.reviews`"永久证据链"只剩最后一轮内容,与 AGENTS.md "评审记录随分支提交 = 永久证据链"的表述不符。
  修法(一句话):round>1 的两个 ask 内插上一轮 `merged.findings`(replayed value,AmendWorkflow cache 安全),并把 persona 改成"若 .reviews 已有记录,在其上追加本轮、保留历史"。

- **[P2] `.zcode/workflows/implement-with-review.dwf.ts:93-104,148-157` — 挑战者 verdict 无校准,REJECTED+零 findings 走空转路径。**
  CHALLENGER_PERSONA 定义了四个镜头和"反对必须有可复现证据",但从未说明何时返回 APPROVED(评审员席可从 review.sh 清单与仓库"无 P1 → APPROVED"门禁继承校准;挑战者席没有任何锚)。路径:挑战者返回 REJECTED 而 findings 为空(或只有 P3,如 MUST KILL 被标 P3)→ 合取后 merged REJECTED、`blockingNow` 为空 → :149 的 break 需 APPROVED,不满足 → :153 修复 ask 携带空 `[]`("修复以下全部 P1/P2 意见"配空列表)→ 实现者无事可修 → 下轮全量重审大概率原样重复 → 烧满 3 轮。
  查证结论:**不是死锁**——循环有界(≤3),必然终止;后果是 2 个实现者会话 + 4 个评审会话纯浪费,且最终 conclusion 为"评审未批准,不要合并"但 findings 为空——人类拿到不可行动的拒绝,只能整轮重跑。
  修法(一句话):挑战者 persona 补一句校准("无 P1 即 APPROVED;REJECTED 必须伴随至少一条 P1/P2"),或脚本对 `verdict===REJECTED && blockingNow.length===0` 显式分支(break+log,或把 evidence 摘进 conclusion 让拒绝可行动)。

**P3**

- **[P3] `.zcode/workflows/implement-with-review.dwf.ts:204` — 所有 findings 硬编码 `status: "verified"`。** 两席并行是互相独立的评审,没有任何一席复核过另一席的发现;按 dynamic-workflows §10,"verified" 意为独立确认过,挑战者单方发现也被标 verified,夸大确认等级。且 `evidence` 字段填的是 `suggestion`(修法)而非证据——逐条 finding 与证据的关联丢失(两席 evidence 数组只进了 verified[] 汇总)。修法:status 按来源标(unconfirmed 或两席都命中才 verified),evidence 改引用 findings 自带的 where/problem。
- **[P3] `.zcode/workflows/implement-with-review.dwf.ts:170-172` — `artifact.file` 的 catch 只 log 不修复。** 技能指引是"rejected publish 是修复机会":应把缺口交回评审员重写记录再发布;这里吞掉后仅靠 markdown 报告兜底。可接受的降级,但低于指引。
- **[P3] `.zcode/skills/recall-nemonotch/SKILL.md:14` — "`plans/archive/`" 路径速写不精确。** 实际路径是 `docs/superpowers/plans/archive/`(已验证存在);裸写 `plans/archive/` 会引导执行代理先撞仓库根下不存在的路径。低影响(recall 场景会自行 glob),顺手改全即可。

## 已验证无问题的面(证据)

- **vendored 未改动(梯级 4,亲跑 diff)**:`diff -rq /tmp/superpowers/skills .zcode/skills --exclude=recall-nemonotch --exclude=PROVENANCE.md` → **零差异**(唯一输出 "Only in .zcode/skills: superpowers-LICENSE",该文件与上游 LICENSE 逐字节一致,`diff` 退出 0)。上游确认 v7.0.1(`git describe --tags` = v7.0.1;package.json 7.0.1)。PROVENANCE.md 声明属实。
- **TypeScript/dynamic-workflows 编译级正确性(梯级 4)**:工作流已注册为项目 saved workflow(ListSavedWorkflows 可见 `implement-with-review` project scope);SaveWorkflow 写入前经同一编译器 typecheck,能入库即编译通过。逐项复核:循环内 `Promise.all` 是必要 join(合并需双方 verdict,有注释);computed 名字含轮次后缀、轮间唯一;`final!` 收紧安全(循环至少跑一轮);`report(merged)` 为纯对象;artifact id 全字面量、单一 `primary: true`、reject 可 catch。
- **挑战者四镜头判据可执行**(:95-101):①并发时序点名具体目标(观察追踪/主线程阻塞/HookServer 持有-超时-连接生命周期/窗口重建)②错误路径点名坏输入/超时/授权缺失/CLI 版本差异③注释审判给出四类白名单(法律头/外部强加/公共 API 契约/lint 抑制)④影响面点名 `ripwire --callers/--impact` 真跑。MUST KILL 修复指令经 findings JSON 进回流 ask(:154-155),可达。
- **.gitignore 白名单(梯级 4,git check-ignore 实测)**:`.zcode/skills/recall-nemonotch/SKILL.md`、`.zcode/workflows/implement-with-review.dwf.ts`、`.zcode/skills/newdir/file.md` 均不被忽略;`.zcode/workflow-runs/x`、`.zcode/plans/x`(命中 `/.zcode/*`)、`.zcode/workflows/draft.ts`(命中 `/.zcode/workflows/*`)仍忽略。`!` 规则无父子目录陷阱——`.zcode/skills`、`.zcode/workflows` 两个父目录各自被 `!/.zcode/skills/`、`!/.zcode/workflows/` 再包含后才下降,深层文件不被 `/.zcode/*` 匹配(`*` 不跨 `/`),实测新目录深层文件不忽略。
- **doc-audit(梯级 4,亲跑)**:`sh scripts/doc-audit.sh` 退出码 0(六条断言全绿)。AGENTS.md 新增内容未破坏硬字符串;新引用的路径全部存在:`implement-with-review` saved workflow、`docs/superpowers/plans/` 与 `archive/` 子目录、`.reviews/`、`scripts/review.sh`、`git feat-*` 钩子(.githooks/feat.sh 等)、`docs/experience-playbook.md`。
- **AGENTS.md 无内部矛盾**:"序列可验证单元"(工作分解纪律)与"新功能不强制 TDD,已定勿重议"(测试先行与否)不同轴,不冲突;"判决新鲜度"与工作流 conclusion "feat-done 前核对 head 未 rebase"(:199)互相咬合;六原则为"何时触发 → 判据"格式、多处锚到本仓库真实战例(如"hook 协议不可行"误判呼应 AskUserQuestion 节教训),符合手册"只写坑与不变量"哲学;入口分流与既有"修 bug 先落失败测试"一致复述而非矛盾。
- **recall-nemonotch 关键防御在位**:"只读不写、不猜、先核活体状态"(:8)明确;活体状态优先的数据源排序(:12-16)合理;scope 锁定由深度界("能三层内回答就不挖第四层")+ 相邻功能抑制(:18)承担;四段输出契约带强制状态标签(无标签=没完);结尾"问用户是否按下一步执行"防自作主张(:27)。仅上述 P3 一处路径速写。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A — 本分支无产品 Swift 代码/测试;自写部分为工作流脚本与文档,无可测断言面(工作流行为属运行时编排,不适用单测目标)。
- [x] **证据纪律**:提交信息声明与实际相符——vendored 未改动(diff -rq 零差异亲证)、doc-audit 绿(亲跑退出码 0)、gitignore 行为(亲跑 check-ignore)。本记录所有结论附 file:line 或命令输出。
- [x] **Swift 6 并发**:N/A — 无 Swift 改动。
- [x] **最小改动**:AGENTS.md 仅 +12 行(1 段扩写 + 10 行原则),每行可追溯到 pstack 融入任务;.gitignore 最小模式改动;无顺手改邻近内容。
- [x] **错误路径**:工作流失败路径总体响亮(REJECTED 不 break、conclusion 明示"不要合并"、artifact.file 失败有 log)——唯 P2-2 空转路径与 P3-2 吞 publish 为降级点,已列 findings。
- [x] **坑总目录对照**:改动触及 gitignore/worktree 排除(AGENTS.md worktree 三重隔离坑——doc-audit 断言在位);文档对账坑(事实变了代码/手册/断言同改——doc-audit 绿);未触其余坑区。
- [x] **文档同步**:AGENTS.md 已随本分支更新(原则/分流/新鲜度);README 不需改(无用户可见功能变化);PROVENANCE.md 记录 vendored 来源。

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 684318cc195b79677db48ca99759c78aeabfffe4...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。

---

**Verdict 理由**:两条 P2 均为"回流环质量退化 + 有界浪费"级别,不产生错误合并或静默失败(最终 verdict 仍基于诚实的全量重审,人类门禁兜底),无 P1;按本仓库约定(无 P1 → APPROVED)批准合并。两条 P2 建议在下一个触及其中的 feature 里顺手修(一行 persona 校准 + ask 内插上轮 findings),不要为此单独开分支。
