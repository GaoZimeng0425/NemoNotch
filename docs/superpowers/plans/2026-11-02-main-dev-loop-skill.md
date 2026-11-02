# 主对话开发闭环(main-dev-loop)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task(本仓恒选主对话执行,见 spec「容器」节;不用 subagent-driven-development)。Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 9 席动态工作流替换为「主对话执行 + 唯一只读评审子代理」的开发闭环,流程定义工具中立(ZCode 与 Claude Code 同一份),并让 feat-done 对 `.zcode/`、`.claude/` 改动强制评审。

**Architecture:** 流程不变量住 AGENTS.md(两工具自动加载);评审派发 prompt 由 `scripts/review.sh --prompt` 生成(模板住门禁旁);`.claude/skills → .zcode/skills` 相对符号链接让 Claude Code 看到既有技能;`.claude/agents/reviewer.md` 补 Claude Code 侧只读评审人格;`feat-done.sh` 评审触发集加 `.zcode/*` `.claude/*`;退役 `implement-with-review.dwf.ts`。

**Tech Stack:** Markdown、POSIX sh、git pathspec/symlink。

**Spec:** `docs/superpowers/specs/2026-11-02-main-dev-loop-design.md`

## Global Constraints

- 工具中立:AGENTS.md 与 scripts/ 里写「子代理工具」,不出现 Agent / Task / SendMessage / ListSavedWorkflows 等任一工具的工具名。
- 除 `feat-done.sh:123` 评审触发集追加 `'.zcode/*' '.claude/*'` 一处外,不改任何门禁判定语义;测试触发集 `swift_changes`(`:193`)不动;`review.sh` 的既有模板生成与「已有 APPROVED 不覆盖」行为不变。
- 不改 brainstorming / writing-plans / executing-plans / systematic-debugging 技能正文。
- AGENTS.md 只写坑与不变量;doc-audit 硬字符串(`HookServer<br/>127.0.0.1 TCP`、签名身份名、`CLAUDE.md → AGENTS.md` 链接、手册引用脚本路径)不得破坏——每次改 AGENTS.md 后必跑 `sh scripts/doc-audit.sh`。
- 符号链接一律**相对路径**(换机器/换路径不断链)。
- `docs/superpowers/plans/**`(含 archive)里的 subagent-driven 字样是历史,不改。
- 本 feature 无 Swift 改动 → 不产新单测;守卫红/绿用历史提交范围模拟。
- 本 feature 自身按新流程执行:主对话实现,评审用 Task 2 的 `--prompt` 输出派发(第一次 dogfood)。
- 中文,技术名保留。

## Review Focus

1. 纯 README/docs 分支被新触发集误拦 → Task 1 Step 5 负例。
2. `--prompt` 输出的字段行名与 `feat-done.sh` 的 grep(`^Verdict: APPROVED`、`^Reviewed-Head:`)不一致 → Task 2 Step 3。
3. AGENTS.md 改写破坏 doc-audit 断言 → Task 1 Step 7、Task 3 Step 4。
4. 符号链接写成绝对路径,或 `.gitignore` 改动把 `.zcode/skills/` 重新忽略 → Task 4 Step 2、Task 5 Step 2。
5. 手册把停顿写成「告知即走」或新增第二停顿(spec 反目标)→ Task 3 Step 3 弱检 + Task 6 Step 2 评审镜头。

---

### Task 1: feat-done 评审触发集纳入 `.zcode/` `.claude/` + AGENTS.md 评审门禁句(同一提交)

**Files:**
- Modify: `.githooks/feat-done.sh:113-125`(注释 + `review_triggers` pathspec + 跳过提示)
- Modify: `AGENTS.md`(所有「代码/scripts/hooks/CI」字样处,预计 2–3 处)

**Interfaces:**
- Produces: pathspec 字面 `'.zcode/*' '.claude/*'`;手册口径「代码/scripts/hooks/CI/.zcode与.claude(技能、人格、工作流)」。

- [x] **Step 1: 守卫先见红——旧触发集放过 `.zcode/` 改动**

Run: `c=$(git log --diff-filter=A --format=%h -- .zcode/workflows/implement-with-review.dwf.ts | tail -1); git diff --name-only "$c^...$c" -- '*.swift' '*.xcodeproj/project.pbxproj' 'scripts/*' '.githooks/*' '.github/*'`
Expected: 无输出(旧门禁会跳过评审)。

- [x] **Step 2: 同样见红——旧触发集放过 `.claude/` 改动**

Run: `c2=$(git log --format=%h -- .claude/settings.json | tail -1); git diff --name-only "$c2^...$c2" -- '*.swift' '*.xcodeproj/project.pbxproj' 'scripts/*' '.githooks/*' '.github/*'`
Expected: 无输出。

- [x] **Step 3: 改 pathspec、注释与提示**

`.githooks/feat-done.sh:123` pathspec 末尾追加 `'.zcode/*' '.claude/*'`;`:116` 注释「改动触及代码/scripts/hooks/CI 的 feature」加「/.zcode 与 .claude(技能、人格、工作流;2026-11-02:流程文本毒害面最大)」;`:125` echo 改「本 feature 无代码/脚本/hooks/CI/.zcode/.claude 改动 — 跳过评审门禁」。

- [x] **Step 4: 见绿——两个历史范围用新 pathspec 均命中**

Run: Step 1、Step 2 的命令,pathspec 末尾各加 `'.zcode/*' '.claude/*'`
Expected: 分别输出 `.zcode/workflows/implement-with-review.dwf.ts` 与 `.claude/settings.json`。

- [x] **Step 5: 负例——纯文档提交不被误拦**

Run: `git diff --name-only 1d410ab^...1d410ab -- '*.swift' '*.xcodeproj/project.pbxproj' 'scripts/*' '.githooks/*' '.github/*' '.zcode/*' '.claude/*'`(1d410ab 只动 docs/)
Expected: 无输出。

- [x] **Step 6: AGENTS.md 评审门禁口径同步**

Run: `rg -n "代码/scripts/hooks/CI" AGENTS.md`;每处改为「代码/scripts/hooks/CI/.zcode与.claude(技能、人格、工作流)」。

- [x] **Step 7: doc-audit 绿**

Run: `sh scripts/doc-audit.sh; echo exit=$?`
Expected: `exit=0`。

- [x] **Step 8: Commit**

```bash
git add .githooks/feat-done.sh AGENTS.md
git commit -m "gate(review): 评审触发集纳入 .zcode/ 与 .claude/(技能、人格、工作流)——流程文本毒害面最大;手册口径同步"
```

---

### Task 2: `scripts/review.sh --prompt [--prev <head>]` 评审派发 prompt 输出模式

**Files:**
- Modify: `scripts/review.sh`(新增参数分支;既有路径零改动)

**Interfaces:**
- Produces: `sh scripts/review.sh <name> --prompt` → stdout 打印派发 prompt,退出 0,**不写任何文件**;`--prev <short-sha>` 切增量复审段。占位符字面 `<<填:症状/需求事实,不含实现思路>>`。Task 6 与 AGENTS.md(Task 3)引用此命令。

- [x] **Step 1: 实现 `--prompt` 分支**

在参数解析处识别 `--prompt`(及可选 `--prev <sha>`),走独立函数输出 heredoc,然后 `exit 0`。prompt 必须含:角色(未参与开发,judge≠author)、worktree 绝对路径(由脚本所在仓库根推得)、diff 范围(默认 `develop..HEAD`;`--prev` 时为 `<prev>..HEAD` 且加「零代码漂移检查 `git diff <prev>..HEAD -- . ':!.reviews'`、维持或改判、bump Reviewed-Head」段)、事实占位符、「先跑 `sh scripts/review.sh <name>` 拿清单逐项过;亲跑 lint/doc-audit/check-arch/affected-tests 引用真实退出码」、bug 专项三镜头(失败测试红→绿可重放 / 修复与根因因果对应 / 旧口径全仓 grep 清场)、输出格式=完整 `.reviews/<name>.md` 记录全文(行名 `Reviewer:` / `Verdict: APPROVED|CHANGES_NEEDED|无法验证` / `Reviewed-Head: <git rev-parse --short HEAD>` / Findings P1–P3 带 file:line)、**铁律段**(零 git 状态变更:不 pull/push/merge/rebase/checkout/commit;不改任何文件;不跑 build.sh;记录全文返回由调用方落盘)。

- [x] **Step 2: 既有行为不变**

Run: `sh scripts/review.sh probe-x >/dev/null; test -f .reviews/probe-x.md && echo "template still generated ✓"; rm .reviews/probe-x.md`
Expected: `template still generated ✓`。

- [x] **Step 3: `--prompt` 字段对齐、铁律、不写文件、增量段**

Run: `out=$(sh scripts/review.sh probe-x --prompt); echo "$out" | rg -c "Verdict: APPROVED|Reviewed-Head:|Reviewer:"; echo "$out" | rg -c "pull|push|build\.sh"; echo "$out" | rg -c "红→绿|因果|grep"; test ! -e .reviews/probe-x.md && echo "no file written ✓"; sh scripts/review.sh probe-x --prompt --prev abc1234 | rg -c "abc1234\.\.HEAD"`
Expected: 第一计数 ≥3,第二 ≥3,第三 ≥3,`no file written ✓`,末计数 ≥1。

- [x] **Step 4: Commit**

```bash
git add scripts/review.sh
git commit -m "review.sh: --prompt [--prev] 输出工具中立的评审派发 prompt(铁律/bug 镜头/字段与门禁 grep 对齐)"
```

---

### Task 3: AGENTS.md「任务入口分流」改写为流程不变量 + 旧口径清场

**Files:**
- Modify: `AGENTS.md:236`(「任务入口分流(三入口,硬路由)」整条)及 Step 1 其他散文命中

**Interfaces:**
- Consumes: Task 2 命令 `sh scripts/review.sh <name> --prompt [--prev <head>]`;Task 4 的 `.claude/skills` 链接(可在手册「两工具同一流程」句提及)。

- [x] **Step 1: 列旧口径残留(历史 plans 与本 spec 排除)**

Run: `rg -n "implement-with-review|实现子代理|免闸|subagent-driven|四参|symptom 入口" AGENTS.md docs/ README.md README_CN.md --glob '!docs/superpowers/plans/**' --glob '!docs/superpowers/specs/2026-11-02-main-dev-loop-design.md'`
Expected: 命中清单(至少 AGENTS.md:236)。

- [x] **Step 2: 改写三入口条目为流程不变量**

替换为一条(可带短子列表),必须含:①执行者=主对话,唯一必需子代理=评审员;两工具(ZCode / Claude Code)同一流程,按各自子代理工具派发;②新需求 `brainstorming → spec → writing-plans → 用户批准 plan(=停顿)→ executing-plans 主对话实现(本仓恒选;subagent-driven-development 不用)→ 门禁 → 评审 → feat-done`;③bug `复现(证据标梯级)→ 根因不明 systematic-debugging(≥2 独立假设且证据不在手才派并行探针,只读回结论)→ 写代码前停顿:根因 file:line+梯级 / 修法 / 影响面 / 刻意不做,等用户一句;未复现首句「根因系推断」→ 失败测试先红 → 修复 → mutate.sh → 门禁 → 评审 → feat-done`;自检四条(复现确凿/证据链成立/修法机械/有确认探针)不满足回去挖、不到提议;免闸五条件作废;④investigation 只读不建 worktree;⑤门禁脚本清单(test.sh 全量写锚点 / lint / doc-audit / check-arch / plan-audit)全绿才派评审;⑥评审派发 = `sh scripts/review.sh <name>` 生成模板 + `--prompt` 输出粘给子代理工具 + 记录原样落盘单独提交(禁编辑);回流 P1/P2 主对话修 → `--prev` 增量复审 ≤3 轮,P3 默认不修;方案被迫变更回停顿;⑦挑战者第二席默认不开,高爆炸半径面(HookServer 协议/钩子脚本/签名部署/持久化格式)在停顿那一拍提议;⑧收尾 feat-done、push 等开口、汇报先背景+「点哪里能看到」+ 一行度量。长度 ≤ 原条目 1.5 倍。

- [x] **Step 3: 清其余命中 + 反目标弱检**

Step 1 其他命中逐处改写/删除(历史复盘改过去时)。Run: `rg -n "等用户一句|停顿" AGENTS.md | head -3`
Expected: 停顿句存在。

- [x] **Step 4: 零残留 + doc-audit 绿**

Run: `rg -n "implement-with-review|实现子代理只照|免闸直通|四参" AGENTS.md docs/ README.md README_CN.md --glob '!docs/superpowers/plans/**' --glob '!docs/superpowers/specs/2026-11-02-main-dev-loop-design.md'; echo "rg exit=$?"; sh scripts/doc-audit.sh; echo "audit exit=$?"`
Expected: `rg exit=1` 且 `audit exit=0`。

- [x] **Step 5: Commit**

```bash
git add AGENTS.md docs/ README.md README_CN.md
git commit -m "docs(agents): 任务入口分流改为主对话执行的工具中立闭环;推翻「实现子代理只照方案」与免闸直通;旧口径清场"
```

---

### Task 4: `.claude/skills` 相对符号链接 + `.claude/agents/reviewer.md`

**Files:**
- Create: `.claude/skills`(symlink → `../.zcode/skills`)
- Create: `.claude/agents/reviewer.md`

**Interfaces:**
- Produces: Claude Code 在本仓可见 `.zcode/skills/` 全部技能;`reviewer` 子代理类型(只读)。

- [x] **Step 1: 探针留档——ZCode 不扫 `.claude/skills`**

Run: `cd /Applications/ZCode.app/Contents/Resources && timeout 90 rg -l --no-messages "claude/skills" glm app.asar.unpacked; echo "rg_exit=$?"`
Expected: `rg_exit=1`(零引用;已于 2026-11-02 实测一次)。若为 0 → 停下,按 spec 退回方案 B(不建链接,改记「Claude Code 装 superpowers 插件」前置)。

- [x] **Step 2: 建相对链接并验证**

Run: `ln -s ../.zcode/skills .claude/skills && readlink .claude/skills && test -f .claude/skills/brainstorming/SKILL.md && echo "resolves ✓"`
Expected: `../.zcode/skills` 与 `resolves ✓`。

- [x] **Step 3: 写 `.claude/agents/reviewer.md`**

frontmatter:`name: reviewer`、`description`(独立评审员——judge≠author,只读,Verdict 三态,Findings 带 P 级)、`tools: Read, Grep, Glob, Bash`。正文与全局 `~/.zcode/agents/reviewer.md` 同义:先跑 `sh scripts/review.sh <name>` 拿清单逐项过;验证亲跑引用真实退出码;`Verdict: APPROVED | CHANGES_NEEDED | 无法验证`;评审对象绑定 `git rev-parse --short HEAD`;**记录全文返回由调用方落盘——不改任何文件、不提交、零 git 状态变更**;中文。

- [x] **Step 4: Commit**

```bash
git add .claude/skills .claude/agents/reviewer.md
git commit -m "claude: .claude/skills → ../.zcode/skills 相对链接(两工具同一技能集)+ 只读 reviewer 人格"
```

---

### Task 5: 退役 implement-with-review 动态工作流

**Files:**
- Delete: `.zcode/workflows/implement-with-review.dwf.ts`
- Modify: `.gitignore:41-43`(删 `!/.zcode/workflows/`、`/.zcode/workflows/*`、`!/.zcode/workflows/*.dwf.ts`)
- 文件系统删除:`.zcode/workflow-drafts/implement-with-review.dwf.ts`

- [x] **Step 1: 删文件与例外行**

Run: `git rm -q .zcode/workflows/implement-with-review.dwf.ts && rm -f .zcode/workflow-drafts/implement-with-review.dwf.ts`;编辑 `.gitignore` 删三行(保留 `/.zcode/*` 与 `!/.zcode/skills/`)。

- [x] **Step 2: 验证 ignore 边界**

Run: `git check-ignore -q .zcode/workflows/x.dwf.ts && echo "workflows ignored ✓"; git check-ignore -q .zcode/skills/brainstorming/SKILL.md && echo "❌ skills ignored" || echo "skills tracked ✓"; git ls-files .zcode/ | cut -d/ -f1-2 | sort -u`
Expected: `workflows ignored ✓`、`skills tracked ✓`,ls-files 只有 `.zcode/skills`。

- [x] **Step 3: Commit**

```bash
git add -A .gitignore .zcode/workflows
git commit -m "chore(workflow): 退役 implement-with-review 动态工作流(ZCode 独有机制,被工具中立闭环取代;历史在 git)"
```

---

### Task 6: 收尾——门禁、新模板评审(dogfood)、合并、两工具验证

**Interfaces:**
- Consumes: Task 2 `--prompt`;Task 1 触发集(本分支动了 `.githooks/`、`scripts/`、`.zcode/`、`.claude/`,评审门禁必然激活)。

- [ ] **Step 1: 勾 Task 1–5 全部框 + 门禁脚本**

Run: `sh scripts/doc-audit.sh && sh scripts/check-arch.sh; echo exit=$?`(无 Swift:lint/test 不适用;plan-audit 由 feat-done 终点跑,此刻 Task 6 框未满不提前跑)
Expected: `exit=0`。

- [ ] **Step 2: 用 `--prompt` 派第一个评审(dogfood)**

Run: `sh scripts/review.sh main-dev-loop-skill && sh scripts/review.sh main-dev-loop-skill --prompt`;把输出的事实占位填为 spec「背景与意图」段事实,用本工具的子代理工具派 `reviewer`;追加一条镜头:手册文本与 spec 目标 2(停顿阻塞)、目标 7(工具中立:无工具名)、反目标(无第二停顿/不假装强制)一致。

- [ ] **Step 3: 记录原样落盘、单独提交**

评审员返回全文 → 写入 `.reviews/main-dev-loop-skill.md`(不编辑一字)→ `git add .reviews/main-dev-loop-skill.md && git commit -m "review(main-dev-loop-skill): <Verdict> @ <Reviewed-Head>"`。

- [ ] **Step 4: 回流(如有 P1/P2)**

主对话修复 → 重跑 Step 1 → `sh scripts/review.sh main-dev-loop-skill --prompt --prev <上轮 Reviewed-Head>` 派增量复审 → 记录更新单独提交;≤3 轮。

- [ ] **Step 5: 勾满 plan 后主检出 feat-done**

Run(主检出): `cd /Users/aa00930/Documents/Learn/macos/NemoNotch && git feat-done main-dev-loop-skill`
Expected: 评审门禁激活并通过,测试门禁「无 Swift 改动跳过」,`--no-ff` 合并,post-merge 钩子构建部署。

- [ ] **Step 6: 合并后验证**

Run(主检出): `readlink .claude/skills && test -f .claude/skills/brainstorming/SKILL.md && echo "claude skills ✓"; ls .zcode/workflows 2>/dev/null | wc -l; git feat-list`
Expected: `claude skills ✓`;workflows 目录为空或不存在;`git feat-list` 触发 freshness 发现 `.githooks/feat-done.sh` 源变更并自动重装(有重装提示)。Claude Code 侧由用户在本仓打开 `claude` 确认技能可见、`review.sh --prompt` 输出可粘给其子代理工具。

- [ ] **Step 7: 汇报与度量**

按手册收尾格式汇报(改前/改后、点哪里能看到),记本 feature 的 token/时长/停顿次数(1:plan 批准,另加本次两轮方案修订)/评审轮数作为新流程首个基线;会话记忆更新(仓库外,不在本 plan)。
