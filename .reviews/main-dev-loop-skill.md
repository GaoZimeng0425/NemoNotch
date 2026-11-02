# Code Review — feature/main-dev-loop-skill

Reviewer: ZCode 独立评审子代理(judge ≠ author,未参与开发、不见作者对话)
Date: 2026-11-02
Reviewed-Head: 5464ce1
Verdict: APPROVED
Scope:  9 files changed, 461 insertions(+), 495 deletions(-)

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

- [P3] `.githooks/feat-done.sh:147` — 评审门禁失败消息仍枚举「代码/脚本/hooks/CI 改动」,触发集已扩到 `.zcode/*`/`.claude/*`,报错文案未同步(只动 `.claude` 的 feature 被说成"有代码改动",排障误导)。修法:消息补「/.zcode/.claude」字样,一行。
- [P3] `scripts/review.sh:92`(**存量,非本分支引入**,082fda1 基线即有)— `echo "✋ 找不到分支 $branch。"` 中 `$branch` 后紧跟全角句号,shell 把句号吞进变量名,`set -u` 下报 `branch。: unbound variable` 而非友好消息(实测 `sh scripts/review.sh probe-x` → exit 1、零文件,fail-closed 仍成立)。修法:`${branch}` 加花括号。
- [P3] `docs/superpowers/plans/2026-11-02-main-dev-loop-skill.md:100`(Task 2 Step 2)— 勾选的验证**不可重放**:实跑 `sh scripts/review.sh probe-x` 因分支不存在 exit 1 且不生成 `.reviews/probe-x.md`,Expected「template still generated ✓」在当前环境不可能出现。命题本身无恙(我已实证:真实分支名跑非 `--prompt` 模式正常走到「已填 Verdict 不覆盖」exit 0,且 diff 显示模板生成代码零改动),但该勾的验证声明与证据纪律梯级 4 不符。修法:补一条可重放验证或在 plan 备注前置条件。

## 追加镜头核对结论(派发方指定)

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

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A——无 Swift 改动、无新测试;守卫判别力由红/绿重放承担(已过)。
- [x] **证据纪律**:提交信息声明与我的独立重放一致;一处例外见 Findings P3(plan Task 2 Step 2 验证不可重放)。
- [x] **Swift 6 并发**:N/A——零 Swift 改动。
- [x] **最小改动**:9 文件全部可追溯 spec「已定设计」;`review.sh` 既有模板生成路径零改动(diff 实证);`.zcode/skills/` 正文未动;README 无旧口径无需改。
- [x] **错误路径**:`--prev` 缺值/未知参数 exit 2;分支不存在 exit 1(带存量报错瑕疵,见 P3);`--prompt` 不写任何文件(实跑后无 `.reviews/probe-x.md`)。
- [x] **坑总目录对照**:改到 hooks——freshness 自检会自动重装 feat-done 副本(plan Task 6 Step 6 已预见);符号链接遵循手册相对路径纪律;worktree 三重排除未破坏(doc-audit 过)。
- [x] **教训候选**:见下。
- [x] **文档同步**:AGENTS.md 评审门禁句/任务入口分流同步;doc-audit 绿;feat-done 错误消息一处滞后(P3)。
- [x] **工作流机制清场**:`implement-with-review` 全仓仅存 spec 自身叙事(非目标声明历史不改写,plans/archive 排除);「实现子代理只照/四参/symptom 入口」零命中;「免闸直通」唯一命中 AGENTS.md:238 是作废宣告句,非残留。

## 教训候选

- `scripts/review.sh:92`(存量):中文消息里 `$var` 后紧跟全角标点,shell 把标点字节吞进变量名,`set -u` 下变 unbound 错——**中文文案里的变量一律写 `${var}`**。判据可机器化(grep `$` 后跟非 ASCII 的形状),是否进 check-arch 留给 reflect 分流。
- plan 勾选的验证命令引用不存在的分支名(probe-x),Expected 在重放环境必不出现——「验证声明可重放」目前只靠评审目测,plan-audit 可考虑弱检「验证命令引用的分支须存在」,记入 guardrail-backlog 候选。
