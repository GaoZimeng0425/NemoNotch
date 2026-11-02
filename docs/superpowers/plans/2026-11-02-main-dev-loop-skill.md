# main-dev-loop 技能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task(本仓恒选主对话执行,见 spec「容器」节;不用 subagent-driven-development)。Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 9 席动态工作流替换为「主对话执行 + 唯一只读评审子代理」的开发闭环技能,并让 feat-done 对 `.zcode/` 改动强制评审。

**Architecture:** 新技能 `.zcode/skills/main-dev-loop/` 串既有 superpowers 技能(brainstorming / writing-plans / executing-plans / systematic-debugging),加「写代码前技术方案停顿」与模板化评审派发;AGENTS.md 三入口段改执行者为主对话;`.githooks/feat-done.sh` 评审触发集加 `.zcode/*`;退役 `implement-with-review.dwf.ts`。

**Tech Stack:** Markdown 技能文件、POSIX sh 钩子、git pathspec、ZCode Agent/SendMessage 工具。

**Spec:** `docs/superpowers/specs/2026-11-02-main-dev-loop-design.md`

## Global Constraints

- 除 `feat-done.sh:123` 评审触发集加 `'.zcode/*'` 一处外,不改任何脚本/钩子语义;测试触发集 `swift_changes`(`:193`)不动。
- 不改 brainstorming / writing-plans / executing-plans / systematic-debugging 四个技能正文。
- AGENTS.md 只写坑与不变量;doc-audit 硬字符串(`HookServer<br/>127.0.0.1 TCP`、签名身份名、手册引用脚本路径)不得破坏——每次改 AGENTS.md 后必跑 `sh scripts/doc-audit.sh`。
- `docs/superpowers/plans/**`(含 archive)里的 subagent-driven 字样是历史,不改。
- 本 feature 无 Swift 改动 → 不产新单测(仓库规则);守卫红/绿用历史提交范围模拟。
- 评审 prompt 模板不含实现思路;评审员零 git 状态变更、不改文件、不 build.sh。
- 本 feature 自身按新流程执行:主对话实现,评审用 Task 2 的模板派发(第一次 dogfood)。
- 中文,技术名保留。

## Review Focus

1. 纯 README/docs 分支被新触发集误拦 → Task 1 Step 4 负例。
2. 模板里字段行名与 `feat-done.sh` 的 grep(`^Verdict: APPROVED`、`^Reviewed-Head:`)不一致 → Task 2 Step 3。
3. AGENTS.md 改写破坏 doc-audit 断言 → Task 1 Step 6、Task 3 Step 4。
4. `.gitignore` 改动把 `.zcode/skills/` 重新忽略(技能文件没进 git)→ Task 4 Step 4。
5. 技能文本把停顿写成「告知即走」或新增第二停顿(spec 反目标)→ Task 2 Step 3 弱检 + Task 5 评审镜头。

---

### Task 1: feat-done 评审触发集纳入 `.zcode/` + AGENTS.md 评审门禁句(同一提交)

**Files:**
- Modify: `.githooks/feat-done.sh:113-125`(注释 + `review_triggers` pathspec + 跳过提示)
- Modify: `AGENTS.md`(所有「代码/scripts/hooks/CI」字样处,预计 2–3 处)

**Interfaces:**
- Produces: pathspec 字面 `'.zcode/*'`;手册口径「代码/scripts/hooks/CI/.zcode(技能与工作流)」——Task 3 与 Task 5 沿用。

- [ ] **Step 1: 守卫先见红——用历史提交证明旧触发集放过 `.zcode/` 改动**

Run: `c=$(git log --diff-filter=A --format=%h -- .zcode/workflows/implement-with-review.dwf.ts | tail -1); git diff --name-only "$c^...$c" -- '*.swift' '*.xcodeproj/project.pbxproj' 'scripts/*' '.githooks/*' '.github/*'; echo "old-pathspec exit=$? (期望输出为空=旧门禁会跳过评审)"`
Expected: 无文件名输出(旧触发集对该提交为空)。

- [ ] **Step 2: 改 pathspec、注释与提示**

`.githooks/feat-done.sh:123` 的 pathspec 末尾追加 `'.zcode/*'`;`:116` 注释「改动触及代码/scripts/hooks/CI 的 feature」加「/.zcode(技能与工作流,2026-11-02:流程文本毒害面最大)」;`:125` echo 文案改「本 feature 无代码/脚本/hooks/CI/.zcode 改动 — 跳过评审门禁」。

- [ ] **Step 3: 见绿——同一历史范围用新 pathspec 命中**

Run: `c=$(git log --diff-filter=A --format=%h -- .zcode/workflows/implement-with-review.dwf.ts | tail -1); git diff --name-only "$c^...$c" -- '*.swift' '*.xcodeproj/project.pbxproj' 'scripts/*' '.githooks/*' '.github/*' '.zcode/*'`
Expected: 输出 `.zcode/workflows/implement-with-review.dwf.ts`。

- [ ] **Step 4: 负例——纯文档提交不被新 pathspec 误拦**

Run: `git diff --name-only 1d410ab^...1d410ab -- '*.swift' '*.xcodeproj/project.pbxproj' 'scripts/*' '.githooks/*' '.github/*' '.zcode/*'`(1d410ab = 本分支 spec 提交,只动 docs/)
Expected: 无输出。

- [ ] **Step 5: AGENTS.md 评审门禁口径同步**

Run: `rg -n "代码/scripts/hooks/CI" AGENTS.md` 列出全部命中;每处改为「代码/scripts/hooks/CI/.zcode(技能与工作流)」。

- [ ] **Step 6: doc-audit 绿**

Run: `sh scripts/doc-audit.sh; echo exit=$?`
Expected: `exit=0`。

- [ ] **Step 7: Commit(脚本与手册同一提交)**

```bash
git add .githooks/feat-done.sh AGENTS.md
git commit -m "gate(review): 评审触发集纳入 .zcode/(技能与工作流)——流程文本毒害面最大;手册口径同步"
```

---

### Task 2: 新技能 `main-dev-loop`(SKILL.md + reviewer-prompt.md)

**Files:**
- Create: `.zcode/skills/main-dev-loop/SKILL.md`
- Create: `.zcode/skills/main-dev-loop/reviewer-prompt.md`

**Interfaces:**
- Consumes: Task 1 的手册口径;`scripts/review.sh` 模板字段(`Reviewer:` / `Verdict:` / `Reviewed-Head:`);全局 `~/.zcode/agents/reviewer.md`(只读,返回记录全文)。
- Produces: 技能路径 `.zcode/skills/main-dev-loop/`(Task 3 在 AGENTS.md 引用);`reviewer-prompt.md` 占位符 `{name}` `{worktree}` `{facts}` `{diff_range}`(Task 5 派发时填充)。

- [ ] **Step 1: 写 SKILL.md**

frontmatter:`name: main-dev-loop`;`description` 以「修 bug / 做需求 / 开发闭环 / 从入口到 feat-done」触发。正文必须含且只含以下节(每节以 spec 为准,写不变量不写说明书):
1. 节点归属一句话:主对话执行一切共享上下文节点;唯一必需子代理=评审员;探针/挑战者按需(条件照 spec 表)。
2. 三入口:新需求 `brainstorming → spec → writing-plans → 用户批准 plan(=停顿) → executing-plans`;bug `复现(证据标梯级)→ 根因不明 systematic-debugging → 停顿 → 失败测试 → 修复 → mutate.sh → 门禁 → 评审 → feat-done`;investigation 只读。写明「写代码前自检四条(复现确凿/证据链成立/修法机械/有确认探针)不满足回去挖,不到提议那一步」。
3. 停顿模板(填充式一段):根因 file:line+梯级 / 修法 / 影响面 / 刻意不做 / 「等你一句」;未复现则首句「根因系推断」;高爆炸半径面(HookServer 协议/钩子脚本/签名部署/持久化格式)在此提议加开挑战者第二席。
4. 门禁脚本清单与命令(主对话后台跑):`sh scripts/test.sh`(全量,写锚点)、`sh scripts/lint.sh`、`sh scripts/doc-audit.sh`、`sh scripts/check-arch.sh`、`sh scripts/plan-audit.sh`(有 plan 时)——全绿才派评审。
5. 评审派发:`sh scripts/review.sh <name>` → `Agent(subagent_type: reviewer)` 用 `reviewer-prompt.md` 填充 → 记录全文**原样**写入 `.reviews/<name>.md` → 单独提交该文件(禁编辑评审文本)。
6. 回流:P1/P2 主对话修 → 重跑门禁 → `SendMessage` 续同一评审员增量复审(只核修复提交,bump Reviewed-Head);续话失败新派并携上轮记录全文;≤3 轮;P3 默认不修(≤3 行机械项可顺手)。方案被迫变更时回停顿。
7. 收尾:主检出 `git feat-done <name>`;push 等用户开口;汇报先背景(改前/改后用户看到什么)+「点哪里能看到」;记一行度量(token/时长/停顿次数/评审轮数)。

- [ ] **Step 2: 写 reviewer-prompt.md**

必须含:角色(未参与开发;judge≠author)、`{worktree}`、diff 范围 `git diff {diff_range}`(默认 `develop..HEAD`)、`{facts}`(症状/需求事实,**不含实现思路**)、要求亲跑 `sh scripts/review.sh {name}` 拿清单并逐项过、亲跑门禁脚本引用真实退出码、bug 专项三镜头(失败测试红→绿可重放 / 修复与根因因果对应 / 旧口径全仓 grep 清场)、输出=完整 `.reviews/{name}.md` 记录全文(含 `Reviewer:` / `Verdict: APPROVED|CHANGES_NEEDED|无法验证` / `Reviewed-Head: <git rev-parse --short HEAD>` / Findings P1–P3 带 file:line)、**铁律段**(零 git 状态变更:不 pull/push/merge/rebase/checkout/commit;不改任何文件;不跑 build.sh)、**增量复审段**(续话时:只核 `{prev_head}..HEAD` 修复提交、零代码漂移检查 `git diff {prev_head}..HEAD -- . ':!.reviews'`、bump Reviewed-Head、维持或改判)。

- [ ] **Step 3: 字段对齐与反目标弱检**

Run: `rg -n "^Verdict|^Reviewed-Head|^Reviewer" scripts/review.sh .zcode/skills/main-dev-loop/reviewer-prompt.md | cut -c1-100; rg -c "pull|push|merge|rebase|checkout" .zcode/skills/main-dev-loop/reviewer-prompt.md; rg -n "等你一句|点头|同意" .zcode/skills/main-dev-loop/SKILL.md | head -3; head -4 .zcode/skills/main-dev-loop/SKILL.md`
Expected: 三个字段名在两文件同拼写;铁律计数 ≥1;停顿节含等待字样;frontmatter `name: main-dev-loop`。

- [ ] **Step 4: Commit**

```bash
git add .zcode/skills/main-dev-loop/
git commit -m "skill(main-dev-loop): 主对话开发闭环——9 席→1 席评审,写代码前技术方案停顿,评审派发模板化"
```

---

### Task 3: AGENTS.md「任务入口分流」改写 + 旧口径清场

**Files:**
- Modify: `AGENTS.md:236`(「任务入口分流(三入口,硬路由)」整条)及 Step 1 列出的其他散文命中

**Interfaces:**
- Consumes: Task 2 技能路径 `.zcode/skills/main-dev-loop/`。

- [ ] **Step 1: 列出旧口径残留(历史 plans 排除)**

Run: `rg -n "implement-with-review|实现子代理|免闸|subagent-driven|四参|symptom 入口" AGENTS.md docs/ README.md README_CN.md --glob '!docs/superpowers/plans/**' --glob '!docs/superpowers/specs/2026-11-02-main-dev-loop-design.md'`
Expected: 命中清单(至少 AGENTS.md:236)。

- [ ] **Step 2: 改写三入口条目**

替换为一条,内容必须含:新需求 `brainstorming(主对话对聊)→ spec 落 docs/superpowers/specs/ → writing-plans → 用户批准 plan → executing-plans 主对话实现(本仓恒选;subagent-driven-development 不用)→ 评审 → feat-done`,全程按 `.zcode/skills/main-dev-loop/`;bug `主对话复现(证据标梯级)→ 根因不明 systematic-debugging(≥2 独立假设且证据不在手才派并行探针)→ 写代码前停顿(根因+修法,等用户一句;未复现=推断须确认)→ 失败测试先红 → 修复 → mutate.sh → 门禁 → 评审 → feat-done`;investigation 只读不建 worktree;「免闸直通五条件」作废,前四条为自检清单。长度与原条目同量级,不写说明书。

- [ ] **Step 3: 清其余命中**

Step 1 其他命中逐处改写或删除(历史复盘句改过去时,不写现在时断言)。

- [ ] **Step 4: 复查零残留 + doc-audit 绿**

Run: `rg -n "implement-with-review|实现子代理只照|免闸直通|四参" AGENTS.md docs/ README.md README_CN.md --glob '!docs/superpowers/plans/**' --glob '!docs/superpowers/specs/2026-11-02-main-dev-loop-design.md'; echo "rg exit=$?"; sh scripts/doc-audit.sh; echo "audit exit=$?"`
Expected: `rg exit=1`(零命中)且 `audit exit=0`。

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md docs/ README.md README_CN.md
git commit -m "docs(agents): 任务入口分流改为主对话执行(main-dev-loop);推翻「实现子代理只照方案」与免闸直通;旧口径清场"
```

---

### Task 4: 退役 implement-with-review 动态工作流

**Files:**
- Delete: `.zcode/workflows/implement-with-review.dwf.ts`(git rm)
- Modify: `.gitignore:41-43`(删三行工作流跟踪例外)
- 文件系统删除:`.zcode/workflow-drafts/implement-with-review.dwf.ts`(本就 gitignored)

- [ ] **Step 1: 删文件与例外行**

Run: `git rm -q .zcode/workflows/implement-with-review.dwf.ts && rm -f .zcode/workflow-drafts/implement-with-review.dwf.ts`;编辑 `.gitignore` 删除 `!/.zcode/workflows/`、`/.zcode/workflows/*`、`!/.zcode/workflows/*.dwf.ts` 三行(保留 `/.zcode/*` 与 `!/.zcode/skills/`)。

- [ ] **Step 2: 验证 ignore 边界**

Run: `git check-ignore -q .zcode/workflows/x.dwf.ts && echo "workflows ignored ✓"; git check-ignore -q .zcode/skills/main-dev-loop/SKILL.md && echo "❌ skills ignored" || echo "skills tracked ✓"; git ls-files .zcode/`
Expected: `workflows ignored ✓`、`skills tracked ✓`,`ls-files` 只列 `.zcode/skills/**`。

- [ ] **Step 3: Commit**

```bash
git add -A .gitignore .zcode/workflows
git commit -m "chore(workflow): 退役 implement-with-review 动态工作流(被 main-dev-loop 技能取代;历史在 git)"
```

---

### Task 5: 收尾——门禁、新模板评审(dogfood)、合并

**Interfaces:**
- Consumes: Task 2 `reviewer-prompt.md`;Task 1 触发集(本分支动了 `.githooks/` 与 `.zcode/`,评审门禁必然激活)。

- [ ] **Step 1: 勾 plan 框 1–4 任务 + 门禁脚本**

Run: `sh scripts/doc-audit.sh && sh scripts/check-arch.sh; echo exit=$?`(无 Swift 改动:lint/test 不适用,feat-done 的 `swift_changes` 为空会跳过测试;plan-audit 由 feat-done 在合并时跑,此刻 Task 5 框未满必红,不提前跑)
Expected: `exit=0`。

- [ ] **Step 2: 生成评审模板并按新模板派发(第一次 dogfood)**

Run: `sh scripts/review.sh main-dev-loop-skill`;用 `reviewer-prompt.md` 填充 `{name}=main-dev-loop-skill`、`{worktree}`、`{facts}`=spec「背景与意图」段事实、`{diff_range}=develop..HEAD`,`Agent(subagent_type: reviewer)` 派发;评审镜头加一条:技能文本与 spec 目标 2(停顿阻塞)、反目标(无第二停顿/不假装强制)一致。

- [ ] **Step 3: 记录原样落盘、单独提交**

评审员返回全文 → 写入 `.reviews/main-dev-loop-skill.md`(不编辑一字)→ `git add .reviews/main-dev-loop-skill.md && git commit -m "review(main-dev-loop-skill): <Verdict> @ <Reviewed-Head>"`。

- [ ] **Step 4: 回流(如有 P1/P2)**

主对话修复 → 重跑 Step 1 门禁 → `SendMessage` 续同一评审员增量复审 → 更新记录单独提交;≤3 轮。

- [ ] **Step 5: 勾满 plan 后主检出 feat-done**

Run(主检出): `cd /Users/aa00930/Documents/Learn/macos/NemoNotch && git feat-done main-dev-loop-skill`
Expected: 评审门禁激活并通过(`Verdict: APPROVED … Reviewed-Head ✓`),测试门禁「无 Swift 改动跳过」,`--no-ff` 合并,post-merge 钩子构建部署。

- [ ] **Step 6: 合并后验证**

`ListSavedWorkflows` 不再列 project 级 `implement-with-review`;主检出跑 `git feat-list`,freshness 检查发现 `.githooks/feat-done.sh` 源变更并自动重装(输出重装提示);`.zcode/skills/main-dev-loop/SKILL.md` 在主检出存在。

- [ ] **Step 7: 汇报与度量**

按技能收尾格式汇报(改前/改后、点哪里能看到),记本 feature 的 token/时长/停顿次数(1:plan 批准)/评审轮数作为新流程首个基线;会话记忆更新(仓库外,不在本 plan)。
