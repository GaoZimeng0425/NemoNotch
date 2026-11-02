# 主对话开发闭环(main-dev-loop)设计

日期:2026-11-02
状态:待用户批准
来源:2026-11-02 工作流事故复盘(用户裁定「现在的流程完整不正确」,按 Anthropic 子代理原则重构)

## 背景与意图

**改之前用户身上发生的事**:一行级 bug 修复(HookServer 分帧)走 implement-with-review 工作流 bug 入口,1h16m 才到第 6/10 阶段、烧 10.86M token,被用户喊停;诊断三阶段花 25 分钟重复推导主对话已验证并喂入的证据;实现者子代理单步骤沉默 34 分钟,期间(时间窗重合,无命令级实锤)对 develop 跑了裸 `git pull` 把三个 merge 提交重写并推上 origin;用户中途问「为什么用字符串实现判断」,流水线与主对话都继续往前跑,无人应答。这是第三例流程膨胀(2026-09-30 / 10-28 / 11-02)。

**用户的两条裁定**:① 流程形状错了,不是慢——有些节点不该由 subagent 承接,该主 agent 自己执行(Anthropic 原则);② **写代码前必须停一拍把技术方案说给用户听**——「我应该知道技术方案」。

**原则依据(一手材料)**:Claude Code sub-agents 文档(主对话适用情形:「phases share significant context (e.g., planning + implementation + testing)」「频繁往返/迭代修正」「非 fork 子代理从零开始要重新收集上下文」;子代理适用:并行互不依赖 / 长输出不想进主对话 / 没见过代码的评审者 / 需要更少工具;「workflows that run in the main conversation context → 用 Skills」)、code.claude.com/docs/en/best-practices(「把同一个任务交给子代理不会让答案更好」;确定性门禁兜底必须发生/绝不发生)、Building Effective Agents(「最简单可行的方案,复杂度只在可证明改善时增加」)、multi-agent research system(多 agent ≈ 聊天 15× token;coding 本质顺序;所有 agent 共享上下文/相互依赖多的领域是差适配)。

## 目标 / 非目标 / 反目标

**目标**
1. 干活的人 = 跟用户说话的人:主对话执行全部需要共享上下文的节点,用户随时能插话且必被应答。
2. 技术方案停顿:写代码前(见「停顿」节),用户点头才动手。
3. 子代理只用于四类正当场景;默认流程里**唯一必需的子代理 = 评审员**。
4. 按复杂度配力:根因已验证的小修复 = 失败测试→修复→评审→feat-done,不写长 plan、不派探针。
5. feat-done 六道机械门禁(merge-tree / doc-audit / plan-audit / check-arch / 评审记录 / 全量测试)原样保留,仍是唯一硬强制层(提示词不假装强制)。
6. 成本目标:同类小修复端到端 ≤ 30 分钟、token ≤ 2M(对照 2026-11-02 基线 1h16m+ 未完成 / 10.86M)。

**非目标**
- 不改 feat-done / git 钩子 / scripts/*.sh 的任何语义。
- 不改 brainstorming / writing-plans / executing-plans / systematic-debugging 技能正文,只路由到它们;「生成技能文本不覆盖本仓门禁」条款继续生效。
- 不处理全局保存工作流 `dev-loop`(其他仓库用)与全局 agents 人格 `implementer`(其他仓库用;本仓开发循环不再调用它,人格文件不动)。
- 不重写历史 plan 文档/archive 里的 subagent-driven 字样(历史记录不改写)。

**反目标(做成了也算失败)**
- 新流程出现第二个默认停顿点——用户要的是知道方案,不是每步签字。
- 用提示词假装强制而脚本层无兜底。
- 重新引入「每任务一个实现者子代理」。
- 评审 prompt 恢复手搓(必须模板化,铁律写死在模板里)。

## 方案对比

- **A(选定):主对话技能 + AGENTS.md 路由改写 + 退役动态工作流。** 新技能当执行清单串既有 superpowers 技能,评审派发模板化。Anthropic 文档明说主对话上下文的工作流用 Skill 承载。代价:技能=提示词无硬强制——但硬强制本来就该在 feat-done 脚本(best-practices 的分工)。
- **B:动态工作流砍成「一个常驻 lead + 评审」两席。** token 从 9 席降到 2 席,但 lead 仍是子代理,跟用户说话只能走工作流提问机制,「写代码前听方案」退化为通知卡——只解决贵,不解决「不跟我讨论」。否。
- **C:只改 AGENTS.md 不写技能。** 步骤散在长手册里、无可调用入口、评审 prompt 每次手搓——今天裸 pull 事故就是「手搓 prompt 漏一条铁律」的后果。否。

## 已定设计

### 节点归属(9 席 → 1 席)

| 节点 | 旧(工作流) | 新 | 依据 |
|---|---|---|---|
| 复现/诊断 | 复现侦探子代理 | **主对话**(先重放症状,证据标梯级;根因不明走 systematic-debugging) | 共享上下文、要跟用户对话 |
| 并行探针 ×3 | 固定 3 子代理 | **按需**:≥2 个真独立假设且证据不在手才派(dispatching-parallel-agents,只读、只回结论),默认 0 | 并行独立是子代理正当场景;无条件派=重复劳动 |
| 诊断挑战者 | 子代理 | **并入评审员**(评审带 bug 专项镜头) | 独立性有价值但不并行、输出短 |
| 建 worktree + plan | 建环者子代理 | **主对话**(`git feat` 是脚本;plan 需要对话里的设计上下文) | 共享上下文 |
| 实现 | 实现者子代理 | **主对话**(executing-plans;失败测试→修复→变异验证) | 「planning+implementation+testing 共享上下文」原文点名;**推翻 2026-10-23「实现子代理只照方案做」拍板** |
| 验证工兵 | 子代理 | **取消**——主对话后台跑 `scripts/test.sh`(全量,写锚点)+ lint + doc-audit + check-arch + plan-audit,脚本输出已压缩 | 长输出压缩=脚本已做;见反目标「手搓」 |
| 评审员 | 子代理 ×2(评审+挑战) | **唯一必需子代理**(reviewer agent;只读;返回记录全文) | 「没见过代码怎么写的评审者」——judge≠author |
| 挑战者第二席 | 子代理 | **默认不开**;改动触及高爆炸半径面(HookServer 协议/钩子脚本/签名部署/持久化格式)时,主对话在方案停顿那一拍向用户提议加开 | 同一任务第二份不更好只更贵 |
| 修复回流 / 交付 | 子代理 | **主对话** | 共享评审结论与实现上下文 |

### 三入口保留,只换执行者

- **新需求(feature)**:brainstorming(主对话)→ spec → writing-plans → **用户批准 plan(=技术方案停顿)** → executing-plans(主对话逐任务,一任务一验证一提交)→ 门禁脚本全绿 → 评审 → feat-done。writing-plans 模板里「subagent-driven-development (recommended) or executing-plans」的选择题,本仓**恒选 executing-plans**(手册赢条款,不改技能正文)。
- **bug**:主对话复现(先重放;证据逐条标梯级)→ 根因未知走 systematic-debugging(≤3 假设并行探针规则见上)→ **根因 + 修法停顿**(见下;未复现的根因必须明说「系推断,未经用户确认不进修复」——免闸直通五条件保留但裁决者从「挑战者子代理」改为「主对话向用户一句话确认」)→ 失败测试(引用真实失败输出)→ 修复 → `scripts/mutate.sh` 变异验证 → 门禁脚本 → 评审 → feat-done。
- **investigation**:只读,引用证据直接作答,不建 worktree(不变)。

### 技术方案停顿(唯一新增停顿)

- bug:动手写代码前,一段话——根因(file:line + 梯级)/ 修法(一句话到一段)/ 影响面 / 刻意不做什么;用户「同意」或改完才写。格式对齐用户汇报偏好(先背景:改之前用户看到什么/改之后看到什么)。
- feature:plan 批准即此停顿,不另加。
- 评审 NEEDS_CHANGES 的回流修复不重停(方案没变);若评审意见迫使方案变更,回停顿。

### 评审派发(模板化,防手搓)

1. 前置:门禁脚本全绿才派(test/lint/doc-audit/check-arch/plan-audit——即旧「验证工兵」的活,由主对话后台 Bash 跑,输出本就被脚本压缩)。
2. `sh scripts/review.sh <name>` 生成 `.reviews/<name>.md` 模板。
3. Agent(`subagent_type: reviewer`,全局人格=只读 Read+Bash)按技能内置模板派发:worktree 路径、`git diff develop..HEAD`、症状/需求**事实**(不带实现思路——沿用铁律)、要求亲跑脚本并引用真实退出码、bug 专项镜头(失败测试红→绿可重放、修复与根因因果对应、旧口径全仓 grep 清场)。模板铁律:**零 git 状态变更(不 pull/push/merge/rebase/checkout/commit)、不改任何文件**——评审员把填好的记录**全文返回**,主对话**原样**落盘并单独提交(仅该文件,禁止编辑评审文本;Reviewed-Head 记派发时 head,`.reviews` 提交不计入 code_head,新鲜度门禁天然成立)。
4. 回流:P1/P2 由主对话修复(每轮重新跑门禁)→ SendMessage 续同一评审员**增量复审**(只核修复提交,bump Reviewed-Head);≤3 轮;P3 默认不修(≤3 行机械项可顺手),遗留进评审记录。

### 容器与文件清单

- 新增 `.zcode/skills/main-dev-loop/SKILL.md` + `.zcode/skills/main-dev-loop/reviewer-prompt.md`(模板)。
- AGENTS.md:「任务入口分流」段改写(执行者=主对话;删「实现子代理只照方案实现」口径;引用新技能;明确本仓 writing-plans 恒选 executing-plans;`subagent-driven-development` 本仓不用)。改写遵守手册精简原则:只写坑与不变量,不写功能说明书。
- 退役:`git rm .zcode/workflows/implement-with-review.dwf.ts`(`.gitignore` 有该路径的跟踪例外,需同步调整;`.zcode/workflow-drafts/` 本就 gitignored,文件系统删除即可)。
- 推翻旧口径 ⇒ 全仓 grep 残留(AGENTS.md、docs/ 里的「implement-with-review」散文引用;历史 plan/archive 刻意不改;会话记忆另行更新)。
- **此 feature 本身走新流程**:实现=主对话,评审=一个子代理(它删的是 .ts 工作流 + 加技能 md + 改 AGENTS.md——评审按「代码/scripts/hooks/CI 改动」计,有 .reviews 记录;这本身就是新流程的第一次实测)。

### 度量与验收

- 下一次真实 bug 与真实需求各跑一次新流程,记录 token / 时长 / 停顿次数 / 评审轮数,对照 2026-11-02 基线(1h16m 未完成 / 10.86M token / 9 席)。
- 过程可观察:主对话每阶段一行进度,不刷屏。
- 停顿体验:用户在写代码前看到过根因+修法(本次脑暴对话即为实例)。

## 留给 builder 的

- SKILL.md 正文措辞(分节、触发词 description、何时自动加载);reviewer-prompt.md 具体字句。
- AGENTS.md 改写文本(doc-audit 硬字符串约束不破坏:手册引用的脚本路径必须存在等)。
- `.gitignore` 例外行的精确修改;退役文件的 git 操作顺序。
- 停顿话术模板(技能里给一个填充式示例)。

## 附:基线数据(2026-11-02)

implement-with-review bug 入口,HookServer 分帧修复:10 阶段跑到第 6 阶段用时 1h16m,7 个子代理各载 1.6–2.6M 上下文,合计 10.86M token,未出评审;主对话接手后 ~50 分钟走完 cherry-pick 重建(因 develop 被裸 pull 重写)→ 全量 626/0 → 变异 5/8 红 → lint → 单席评审 APPROVED ×2 轮 → 部署探针 200/200 → feat-done 全门禁合并部署。
