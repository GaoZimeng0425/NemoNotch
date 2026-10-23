# Code Review — feature/absorb-workflow-gates

Reviewer: 独立评审子代理 (zcode session, 2026-10-23)
Date: 2026-10-23
Reviewed-Head: f51cb41
Verdict: CHANGES_NEEDED
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
