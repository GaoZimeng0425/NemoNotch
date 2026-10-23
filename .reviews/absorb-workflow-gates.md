# Code Review — feature/absorb-workflow-gates

Reviewer: 独立评审子代理 (zcode session, 2026-10-23)
Date: 2026-10-23
Reviewed-Head: fa75303
Verdict: APPROVED
Scope:  4 files changed, 83 insertions(+), 3 deletions(-)

```
.githooks/feat-done.sh
AGENTS.md
scripts/plan-audit.sh
scripts/review.sh
```

## Findings

- **[P2] scripts/plan-audit.sh:8-9 vs :27 — 注释声称「archive/ 是历史归档,不重新审判」,但 pathspec `'docs/superpowers/plans/'` 递归包含 `plans/archive/**`,实测 archive/ 下的裸框同样被抓**(评审演示:提交带裸框的 `docs/superpowers/plans/archive/2026-10-23-review-audit-demo.md`,plan-audit exit 1 并列出该文件行号;演示提交已 reset)。现实影响:仓里现存 **23 个归档 plan、9 个活跃 plan 含裸 `[ ]`**(grep 实数);「ship 后 plan 挪 archive/」是手册写明的常规动作,任何分支搬运这些前门禁时代的旧 plan 都会踩红门禁,而排障者读注释会以为 archive 被排除。commit message 的 "Scope: docs/superpowers/plans/ only" 与脚本注释互相矛盾(前者含 archive、后者说排除)。修法二选一:pathspec 加 `':(exclude)docs/superpowers/plans/archive/'`,或删掉注释里「archive/ 不重新审判」半句——二者必须同一提交对齐。
- **[P3] scripts/plan-audit.sh:38 — `grep … "$f" 2>/dev/null || true` 对不可读/不存在文件静默跳过 = 小口子 fail-open**。两条具体路径:(a) 从仓库子目录手动跑(顶层检查只验 git 仓库、不验 cwd,`--name-only` 给的仓库根相对路径全部解析失败 → 所有文件被静默跳过 → 「任务全勾」假绿);(b) 分支已提交的 plan 在工作区被(未提交地)删除。feat-done 接线恒 `cd "$wt"` 根目录,主路径无恙,坑在手动跑。修法:`[ -f "$f" ]` 缺失即响亮退出,或脚本开头 `cd "$(git rev-parse --show-toplevel)"`。
- **[P3] scripts/plan-audit.sh:37-44 — 审计对象是工作区文件,合并带走的是已提交版本**:勾了框但不提交,门禁过、合并的是带裸框的提交版。测试门禁对同款混合态有显式警告(feat-done.sh:143-145),plan 门禁没有——至少补同款 ⚠️。
- **[P3] scripts/plan-audit.sh:19-24 — merge-base 失败/为空时 `git diff` 报错 → plans 为空 → exit 0「跳过」假绿**。病态场景(无共同历史),列出备档。
- **[P3, 既有状态非本次劣化] .githooks/feat-done.sh:5-7 — 头部「流程」注释只列测试门禁**:基线(bdd2915)就未列 doc-audit/评审门禁,本次加 plan-audit 沿袭了同样的沉默。机制清场做到 AGENTS.md 而未到此注释;顺手补齐更好,不拦合并。

### 核对无误的项(负空间,供复审)

- IFS 换行循环正确(空格文件名不拆;glob 字符无匹配时按字面保留);grep 模式正确排除 `[x]`、命中嵌套/星号框、不误伤行内引用(演示文件四形态逐一验证);`--no-renames --diff-filter=AM` 下删除不触发(删行=合法跳过形态)、改名拆成删+增、增侧照审——与注释声明一致。
- feat-done 接线:`(cd "$wt" && sh …)` 子 shell 隔离 cd;`if !` 吸收状态码与 `set -e` 无交互;门禁位于 stash/merge 之前,「worktree 与分支原样保留」属实;逃生变量名 `NEMONOTCH_SKIP_PLAN_AUDIT` 与 AGENTS.md 逐字一致;AGENTS.md 步骤 3 次序(doc-audit → plan → 测试)与脚本实际次序一致(评审门禁位置手册未写=既有状态)。
- review.sh mech:触发集=评审门禁工程面(`.githooks/|scripts/|.github/`)与注释声明一致;`|| true` 在 set -u 下无害;**空 mech_item 渲染与改前模板逐字节同形**(实测:空变量行→空行,非机制分支零 churn);mech_item 为固定字面量、无反引号/文件名注入面。
- 手册对账:worktree 内 `sh scripts/doc-audit.sh` exit 0(六对断言全绿);AGENTS.md 三处散文(观测不成律/bug 根因披露/生成技能不覆盖门禁)与「测试」节「新功能不强制 TDD(已定,勿重议)」等既有口径无矛盾。
- 机制清场 grep(证据):`grep -rn "NEMONOTCH_SKIP" --include='*.md' --include='*.sh'`(全仓,排除 .worktree/)——新变量三处(manual/feat-done/plan-audit)拼写一致,无第四种拼法;`grep -rn "feat-done" docs/`——git-worktree-workflow.md 只述「合并前跑单测 + 独立评审」(仍为真,未列全部门禁、与 doc-audit 同等待遇,无矛盾口径);README/README_CN 同样只述单测,仍为真。未发现与新门禁构成矛盾的旧口径。
- HEAD 考古:实现提交在交接前由 e016be0 **amend 成 f51cb41**(reflog:同作者/时间戳/message;amend 补上了 feat-done 接线 + review.sh + AGENTS.md hunk)。评审期间分支未被评审方改动;任务提示中的 e016be0 系 amend 前过时引用。

## 补审(53f94fd — 2026-10-23,同评审子代理)

修复范围核对:`git show --stat 53f94fd` 仅 scripts/plan-audit.sh(18+/6-),无顺手改动;shellcheck 修复后版零告警。逐条对账(评审实测,演示提交均 `git reset --hard` 复原、HEAD 与 status 终态核对):

- **F1(P2)— 已解决,实测**:pathspec 加 `':(exclude)docs/superpowers/plans/archive/'`,头部注释改为与行为一致并写明理由;红态演示(活跃区 + archive/ 各一个裸框文件)exit 1 且**只列活跃区文件**,archive/ 文件不出现在输出——排除生效,注释/行为/commit message 三者对齐。
- **F3(P3)— 已解决,实测**:勾框不提交 → `⚠️ …有未提交改动 — 门禁审计的是工作区版,合并只带走已提交版` + exit 0;提交后复跑无警告 + exit 0。与测试门禁的混合态警告同款。
- **F4(P3)— 已解决,构造级验证**:`base=$(git merge-base HEAD develop) || { …exit 2; }` 的 POSIX 语义实测(`base=$(false) || handler` 正确触发;赋值语句状态=命令替换状态)加上代码走读确认;未造孤儿分支做全真触发(改动面小、逻辑直白,如实记为构造级)。
- **F2(P3)— 部分解决,残留一条新 P3**(见下):(b) 场景(分支已提交、工作区删文件)已修——实测 exit 1「diff 报有此文件但工作区找不到」,fail-closed 生效;(a) 子目录场景**未修且注释说法被实测推翻**。

**[P3·残留] scripts/plan-audit.sh:44 — 注释称 `[ ! -f ]` 守卫拦「比如从子目录跑」,实测从子目录跑根本到不了该守卫**:git pathspec 相对 **cwd** 解析,从 `docs/superpowers/` 下 `'docs/superpowers/plans/'` 解析到不存在的嵌套路径 → `plans` 为空 → 走「✅ 未动 plan 文档 — 跳过」exit 0 **假绿**(评审演示:子目录下提交了 plan 文件后运行,输出「跳过」)。影响面仅限**手动**从子目录跑——feat-done 接线恒 `(cd "$wt" && …)` 根目录,集成路径不受影响(接线即正确用法);文件头「在 feature worktree 根目录跑」是文档性约束而非机制约束。后续一行修:脚本开头 `cd "$(git rev-parse --show-toplevel)"`,或 pathspec 用 `':(top)'` 魔法(后者顺带让 `[ ! -f ]` 守卫对子目录真正生效)。不拦本次合并,建议随下个触及该文件的 feature 或 guardrail backlog 收口。

开发会话自报的复测四项(archive 不触发/活跃裸框 exit 1/勾后 exit 0/未动 exit 0)与评审实测全部一致。

**Verdict 翻转为 APPROVED 的依据**:唯一 P2(F1)已修并经评审实测确认;新残留为 P3 级(手动误用路径、集成路径经接线与实测双重确认安全),按首轮既定判例(P3 不拦合并)放行。Reviewed-Head 更新为 53f94fd。

### 补审3(fa75303 — 子目录假绿收口)

- **残留 P3 — 已解决,判别场景实测**:fa75303 在仓库检查后加 `cd "$(git rev-parse --show-toplevel)" || exit 2`,子目录运行统一挪到仓根再判。判别测试(分支提交裸框 plan + 从 `scripts/` 子目录跑):**exit 1 并列出 file:行号**——修复前该场景实测为「✅ 跳过」exit 0 假绿,判别力成立;复原后根目录跑 skip exit 0 无回归。`[ ! -f ]` 守卫的子目录来由注释随机制变化自然弱化(守卫仍覆盖工作区删除场景),无需再改。Reviewed-Head 更新为 fa75303。

## 三态复核(评审独立重做,非转述)

在 worktree 以临时提交重演(完成后 `git reset --hard HEAD~2` 复原,HEAD=f51cb41、`git status --porcelain` 仅余本记录未跟踪):

| 态 | 输入 | 结果 |
|---|---|---|
| skip | 分支未动 plan(f51cb41 原状) | `✅ …未动 plan 文档 — 跳过`,**exit 0** |
| red | 演示 plan 含 4 形态框(裸/嵌套缩进/星号/已勾+行内引用) | 列 file:行号(裸/嵌套/星号命中;已勾与行内引用不命中),**exit 1** |
| green | 同文件全部改 `[x]` 后提交 | `✅ …任务全勾`,**exit 0** |

与实现提交 message 自报的 red/green/skip = 1/0/0 一致;reflog 中的 `temp: plan-audit demo (will be reset)` / `temp: tick demo boxes` 两个已 reset 提交佐证开发会话确实做过同款验证。shellcheck(本机 0.10.0)对三脚本仅 SC1091 info(不追踪 source,预期内),新代码零告警。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:N/A(无新增 Swift 测试;门禁本身的鉴别力经三态实测——被审对象全勾时它能过、有裸框时它必红,有牙)
- [x] **证据纪律**:✓ 提交声明 red/green/skip=1/0/0 到第 4 级(评审独立复现同结果 + reflog 佐证原验证发生过)
- [x] **Swift 6 并发**:N/A(无 Swift 改动)
- [x] **最小改动**:✓ 全量 diff(bdd2915...HEAD)逐 hunk 对应任务三项;无顺手改动
- [x] **错误路径**:大体 ✓(exit 1/2 响亮、file:line 可读);F2/F4 两条小 fail-open 口子记录在案
- [x] **坑总目录对照**:✓ 遵守「管道吃退出码→裸命令」「缺工具拦不跳」「逃生阀显式回显」既有约定;grep -E \|\| true 在 set -u 下用法与 playbook 先例一致
- [x] **文档同步**:✓ AGENTS.md 步骤 3 更新、变量名逐字一致;doc-audit 六对断言全绿
- [x] **工作流机制清场**:✓ 已做(证据见「核对无误的项」grep 段);F1 即清场抓出的新脚本自身注释矛盾

## Verdict 说明

CHANGES_NEEDED:唯一 P2 是 F1——门禁脚本的**自身注释**与执行行为在落地首日即矛盾(archive/ 实际被审判),且踩雷面是手册写明的常规动作(旧 plan 归档)。一行修(pathspec 加 exclude 或删注释半句)+ amend,再走 Reviewed-Head 补审即可。其余 P3 不拦合并,可随 F1 顺手或另开。不改动除本记录外的任何文件。
