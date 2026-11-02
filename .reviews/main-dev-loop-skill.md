# Code Review — feature/main-dev-loop-skill

Reviewer: ZCode 独立评审子代理(judge ≠ author,未参与开发、不见作者对话;增量复审 2026-11-02)
Date: 2026-11-02
Reviewed-Head: 7c5c8e7
Verdict: APPROVED
Scope:  首轮 5464ce1(9 files, +461/−495);增量复审 5464ce1..7c5c8e7(3 commits,详见增量小节)

```
.claude/agents/reviewer.md
.claude/skills
.githooks/feat-done.sh
.gitignore
.zcode/workflows/implement-with-review.dwf.ts
AGENTS.md
docs/superpowers/plans/2026-11-02-main-dev-loop-skill.md
docs/superpowers/specs/2026-11-02-main-dev-loop-design.md
scripts/review.sh
```

## Findings

- [P3] `.githooks/feat-done.sh:147` — 评审门禁失败消息仍枚举「代码/脚本/hooks/CI 改动」,触发集已扩到 `.zcode/*`/`.claude/*`,报错文案未同步(只动 `.claude` 的 feature 被说成"有代码改动",排障误导)。修法:消息补「/.zcode/.claude」字样,一行。**[增量已修:127/147 两处文案均补,见增量小节]**
- [P3] `scripts/review.sh:92`(**存量,非本分支引入**,082fda1 基线即有)— `echo "✋ 找不到分支 $branch。"` 中 `$branch` 后紧跟全角句号,shell 把句号吞进变量名,`set -u` 下报 `branch。: unbound variable` 而非友好消息(实测 `sh scripts/review.sh probe-x` → exit 1、零文件,fail-closed 仍成立)。修法:`${branch}` 加花括号。**[增量已修:实跑输出友好消息 exit 1,见增量小节]**
- [P3] `docs/superpowers/plans/2026-11-02-main-dev-loop-skill.md:100`(Task 2 Step 2)— 勾选的验证**不可重放**:实跑 `sh scripts/review.sh probe-x` 因分支不存在 exit 1 且不生成 `.reviews/probe-x.md`,Expected「template still generated ✓」在当前环境不可能出现。命题本身无恙(已实证:真实分支名跑非 `--prompt` 模式正常走到「已填 Verdict 不覆盖」exit 0,且 diff 显示模板生成代码零改动),但该勾的验证声明与证据纪律梯级 4 不符。修法:补一条可重放验证或在 plan 备注前置条件。**[增量已修:Run 改真实分支名 + 计数改按匹配数,照跑得 Expected,见增量小节]**

## 增量复审(5464ce1..7c5c8e7)

范围:033741e(本记录首轮落盘)、f0ef271(修三条 P3)、7c5c8e7(勾 Task 6)。零代码漂移检查:`git diff 5464ce1..HEAD -- . ':!.reviews'` 恰 3 文件——`.githooks/feat-done.sh`(1 行文案)、`scripts/review.sh`(1 行 `${branch}`)、plan(Task 2 Step 2/3 重写 + Task 6 七框勾选),与提交声称一致,无额外改动。

三条 P3 核验(重放,梯级 4 除注明):
- **P3-1**:源码 grep 确认 feat-done.sh 127 行(纯文档跳过提示)与 147 行(门禁未过)两处文案均含「/.zcode/.claude」;`sh -n` exit 0。本项止于梯级 2——铁律禁跑 feat-done(会触发合并流程);改动为静态字符串字面量,shape 由 diff 完全决定,上轮已对触发集逻辑红/绿重放,本轮未动逻辑。
- **P3-2**:实跑 `sh scripts/review.sh probe-x` → 输出「✋ 找不到分支 feature/probe-x。」**exit=1**,unbound variable 消失,fail-closed 保持。
- **P3-3**:照跑 plan 新 Run——Task 2 Step 2 `sh scripts/review.sh main-dev-loop-skill` → `exit=0`、提示「已有已填 Verdict 的记录 — 不覆盖」、`.reviews/main-dev-loop-skill.md` md5 前后一致、`git status --short .reviews` 干净;Task 2 Step 3 计数 3/4/3(均 ≥3)、`no file written ✓`、`--prev abc1234` 段计数 3(≥1)。`rg -c` → `rg -o|wc -l` 按匹配数计的变更合理(Expected 已注明口径),「勿 rm 真实记录」备注防重放者误删。

plan 勾选核对:`grep -c '^- \[ \]' docs/superpowers/plans/2026-11-02-main-dev-loop-skill.md` = **0**。

**Task 6 Step 5–7 预勾立场(派发方按惯例征询)**:接受。feat-done 的 plan-audit 门禁(本分支动过的 plan 不许裸框)与 Step 5–7 描述的动作(feat-done、合并后验证、汇报)结构性自引——不预勾则门禁永远拦住自己,流程死锁;Step 4(增量复审)同属时序自引(勾选先于复审完成,记录更新由派发方在评审员返回后落盘提交)。与 2026-11-02 上午 HookServer 修复同惯例。已知边界:预勾是「将做」的声明,门禁无法验证 Step 6/7 合并后真被执行,该责任仍在主对话执行与用户观察,不因预勾豁免。

增量新 Findings:
- [P3/信息] 7c5c8e7 提交信息「勾选 Task 6 Steps 2–7」与实际勾选范围不符——diff 实勾 **Steps 1–7**(七框,`git show 7c5c8e7 | grep -c '^+- \[x\]'` = 7),Step 1 的勾选未在提交信息中提及。Step 1 的验证内容(doc-audit + check-arch exit=0)已由本轮亲跑复核为真,勾选属实;仅提交信息覆盖不全,审计链上有轻微误导。修法:无需代码改动,增量复审记录的落盘提交信息补记即可。

门禁重放(worktree 内):`sh scripts/lint.sh` → **exit 0**(仅存量 warning);`sh scripts/doc-audit.sh` → **exit 0**;`sh scripts/check-arch.sh` → **exit 0**;`sh -n .githooks/feat-done.sh` → 0;`sh -n scripts/review.sh` → 0。本分支无 Swift 改动,测试门禁 N/A 维持。

新鲜度自洽:记录更新 Reviewed-Head: 7c5c8e7 并提交后,feat-done 门禁(feat-done.sh:160–179,读 `HEAD:.reviews/<name>.md` 的 Reviewed-Head 对比最近非 .reviews 提交)核对 7c5c8e7 == 7c5c8e7 通过。

## 追加镜头核对结论(派发方指定,首轮)

- **目标 2(停顿无条件阻塞)**:一致。`AGENTS.md:237` feature 路径「用户批准 plan(=写代码前的技术方案停顿)」;`AGENTS.md:238` bug 路径「等用户一句再动手」「停顿无条件,要问的人就是用户」——阻塞式、无条件;「免闸直通五条件」显式宣告作废。
- **目标 7(工具中立)**:一致。实测 `rg '\b(Agent|Task|SendMessage|ListSavedWorkflows)\b' AGENTS.md scripts/review.sh .githooks/feat-done.sh .claude/agents/reviewer.md` 零子代理工具名命中(AGENTS.md 三处 `Task` 命中均为 Swift 并发 Task,见 AGENTS.md:122/135/173)。ZCode/Claude Code 作为产品名出现在路由说明句(AGENTS.md:236),与 spec 正文自身用法一致(spec 目标 7 括号例示限定的是 Agent/Task/SendMessage 一类子代理工具名);`--prompt` 输出经实跑确认零工具名。
- **反目标(不新增第二个默认停顿 / 不假装强制)**:一致。每入口恰一个停顿,回流仅在「方案被迫变更」时回停顿,无新默认停顿;硬强制在 feat-done 触发集(红/绿重放见下),手册只写不变量,无「提示词假装强制」。
- **`.claude/skills` 相对路径**:`git ls-files -s` mode 120000(真 symlink),blob 内容 `../.zcode/skills`,`readlink` 实证——相对路径,换机不断链。
- **`.gitignore` 未误伤**:`git check-ignore .zcode/skills/brainstorming/SKILL.md` exit 1(仍 tracked);`.zcode/workflows/x.dwf.ts` 仍被 `/.zcode/*` 兜底忽略;`git ls-files .zcode/` 只剩 `.zcode/skills`;本分支对 `.zcode/skills/` 正文零改动。

## 验证记录(全部亲跑,梯级 4)

- `sh scripts/lint.sh` → **exit 0**(仅存量 warning,无 error);`sh scripts/doc-audit.sh` → **exit 0**(6 项断言全过,含 CLAUDE.md 符号链接与手册脚本路径);`sh scripts/check-arch.sh` → **exit 0**。
- **守卫红/绿重放**(feat-done 评审触发集):旧 pathspec 对 `2b3f434^...2b3f434`(加 `.zcode/workflows` 那次)与 `8f945af^...8f945af`(加 `.claude/settings.json` 那次)均为**空**(旧门禁漏过流程文本 = 红);新 pathspec 分别命中 `.zcode/workflows/implement-with-review.dwf.ts` 与 `.claude/settings.json`(绿);纯文档提交 `1d410ab^...1d410ab` 新 pathspec 仍为**空**(不误拦)。守卫有牙。
- `sh scripts/review.sh main-dev-loop-skill --prompt` → **exit 0**,首轮段正确(范围 `082fda1...HEAD`、字段行/铁律/bug 镜头与 feat-done grep `^Verdict: APPROVED`/`^Reviewed-Head:` 对齐,且与我收到的派发 prompt 逐字一致);`--prompt --prev f5554ed` → **exit 0**,增量段(零代码漂移检查/维持或改判/bump)正确;`--prev` 缺值 → **exit 2** fail-closed;未知参数 → exit 2。
- 本分支无 Swift 改动 → `affected-tests.sh`/`mutate.sh` 不适用(N/A),判据由上述历史提交范围重放替代。
- **增量复审追加**:`sh scripts/review.sh probe-x` → 友好消息 exit 1(P3-2 修复);`sh scripts/review.sh main-dev-loop-skill`(非 prompt)→ exit 0 不覆盖已填记录、文件 md5 不变;plan Task 2 Step 3 新 Run 照跑 → 计数 3/4/3 + `no file written ✓` + `--prev abc1234` 段计数 3;`sh -n .githooks/feat-done.sh` → 0、`sh -n scripts/review.sh` → 0;`grep -c '^- \[ \]' plan` = 0。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A——无 Swift 改动、无新测试;守卫判别力由红/绿重放承担(已过)。
- [x] **证据纪律**:提交信息声明与我的独立重放一致;首轮一处例外见 Findings P3-3(增量已修),增量一处信息性例外见增量 Findings(7c5c8e7 提交信息少报 Step 1)。
- [x] **Swift 6 并发**:N/A——零 Swift 改动。
- [x] **最小改动**:9 文件全部可追溯 spec「已定设计」;`review.sh` 既有模板生成路径零改动(diff 实证);`.zcode/skills/` 正文未动;README 无旧口径无需改;增量恰 3 文件与声称一致。
- [x] **错误路径**:`--prev` 缺值/未知参数 exit 2;分支不存在 exit 1(友好消息,增量已修);`--prompt` 不写任何文件(实跑后 `.reviews` 干净)。
- [x] **坑总目录对照**:改到 hooks——freshness 自检会自动重装 feat-done 副本(plan Task 6 Step 6 已预见);符号链接遵循手册相对路径纪律;worktree 三重排除未破坏(doc-audit 过)。
- [x] **教训候选**:见下。
- [x] **文档同步**:AGENTS.md 评审门禁句/任务入口分流同步;doc-audit 绿;feat-done 错误消息已补 .zcode/.claude(增量)。
- [x] **工作流机制清场**:`implement-with-review` 全仓仅存 spec 自身叙事(非目标声明历史不改写,plans/archive 排除);「实现子代理只照/四参/symptom 入口」零命中;「免闸直通」唯一命中 AGENTS.md:238 是作废宣告句,非残留。

## 教训候选

- `scripts/review.sh:92`(存量,首轮):中文消息里 `$var` 后紧跟全角标点,shell 把标点字节吞进变量名,`set -u` 下变 unbound 错——**中文文案里的变量一律写 `${var}`**。判据可机器化(grep `$` 后跟非 ASCII 的形状),是否进 check-arch 留给 reflect 分流。
- plan 勾选的验证命令引用不存在的分支名(probe-x,首轮),Expected 在重放环境必不出现——「验证声明可重放」目前只靠评审目测,plan-audit 可考虑弱检「验证命令引用的分支须存在」,记入 guardrail-backlog 候选。
- (增量)提交信息描述的勾选范围与 diff 实勾框数不符(说 Steps 2–7 实勾 1–7)——plan 勾选类提交的信息宜按 diff 实际范围写;评审侧核对手段即 `git show <rev> -- <plan> | grep -c '^+- \[x\]'` 对提交信息声称数。
