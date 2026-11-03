# Code Review — feature/autopush-develop

Reviewer: ZCode 独立评审子代理(judge ≠ author;未参与开发,只持 diff、AGENTS.md 与 worktree 只读权)
Date: 2026-11-03
Reviewed-Head: d4cab95
Verdict: CHANGES_NEEDED
Scope:  2 files changed, 27 insertions(+), 4 deletions(-)

```
.githooks/feat-done.sh
AGENTS.md
```

## Findings

- [P2] docs/git-worktree-workflow.md:55-64 — `git feat-done` 流水线注释止于「restore stash → remove worktree, delete the branch」,未提新增的自动 push 步;该文档是 AGENTS.md 点名的流程细节文档(「细节 docs/git-worktree-workflow.md」),读者会带着「feat-done 不推送」的旧心智模型离开。修法:在该注释块尾补一步「→ push origin develop(diverged → loud refusal, **never** auto-pull; `NEMONOTCH_SKIP_PUSH=1` escape)」,与 AGENTS.md:39 同一提交落。
- [P3] docs/superpowers/plans/2026-11-02-main-dev-loop-skill.md:132 — 已执行完的 plan 仍留在 plans/(未按约定 ship 后挪 archive/),其 ⑧ 含被本分支推翻的旧口径「push 等开口」;若日后有人重放该 plan 会把旧行为写回 AGENTS.md。修法:挪 docs/superpowers/plans/archive/,或把 ⑧ 的 push 半句同步为新口径。
- [P3] .githooks/feat-done.sh:280 — SKIP_PUSH 提示走 stdout,而其余五个 SKIP_* 门禁提示(SKIP_DOC_AUDIT/PLAN/ARCH/REVIEW/TESTS)均 `>&2`;纯一致性。修法:行尾补 `>&2`。

代码本体无 P1:六种结局全部亲测实证(见「验证记录」),失败路径全部响亮(rc=1 + stderr + 手动命令)、合并不回滚、分叉绝不自动 pull 且给出的人工命令端到端可走通。

## 教训候选

- .githooks/feat-done.sh:273-295 — `NEMONOTCH_HOOK_DEBUG=1` 只干跑 post-merge 的 build;feat-done 的 merge 与 push 在真仓库照真发生(merge 一直如此,push 自本分支起也是)。判据:以后探 hook/流程行为一律在沙箱 origin 上跑(本次探针即如此),别把 HOOK_DEBUG 当 feat-done 整体干跑。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:本分支无单测目标(shell + 网络行为);沙箱矩阵有鉴别力——[1]/[2] 仅差 feat-done.sh 版本,断言 origin==work 会因「没推」翻红;[3] 同时断言 rc≠0、origin 未被改写、本地合并保留。我已重放,断言真的会咬。
- [x] **证据纪律**:提交信息声明的四段结局逐一重放全部吻合(见「验证记录」);梯级 4(真跑、有退出码)。
- [N/A] **Swift 6 并发**:diff 仅 .githooks/feat-done.sh + AGENTS.md,零 Swift 改动。
- [x] **最小改动**:27 行全部可追溯到需求(push 三段 + 头注释流程链更新 + AGENTS.md 两处口径翻转);无顺手改动邻近代码。
- [x] **错误路径**:fetch 失败 / 分叉 / push 失败 / 成功 / SKIP / 改前六种结局亲测,失败分支全部 rc=1 + stderr 提示 + 可执行的手动命令;`git push -q` 不吞 stderr(X2 实测两行 `fatal:` 可见,「见上」话术成立);fetch 的 `2>/dev/null` 有明确补偿话术。备注(非 finding):post-merge build 失败不拦 push——git 不回传 post-merge 退出码,且用户原话「只要合并的都自动同步」;后果限于 origin/develop 的 CI 变红,develop 非发布通道(发布走 tag + main PR),在拍板范围内。
- [x] **坑总目录对照**:2026-11-02「裸 pull 线性化重写」实案直接对照——绝不自动 pull 已实证([3] origin 顶端仍是 other-side 提交、未被改写);提示中的 `git merge origin/develop && git push` 在真分叉(origin-only=1 / local-only=1)下端到端走通:pre-merge-commit 剥 `origin/` 前缀后按 `develop` 白名单放行,实测合并提交 73812d5 创建成功、push rc=0。freshness 机制交互:本 feature 自己那次 feat-done 仍跑旧装副本(链首已查过 freshness),下次 feat/feat-done 自动重装新副本——既有机制,无需动作。
- [x] **教训候选**:见上(1 条)。
- [x] **文档同步**:AGENTS.md:39(步骤链尾)与 :240(收尾口径)已同步翻转;README.md / README_CN.md 无工作流推送描述(grep 零命中)。缺口 = P2(git-worktree-workflow.md)。
- [x] **工作流机制清场**:全仓 grep「记得推送|等开口|等用户开口|手动 push|手动推送」覆盖 AGENTS.md、docs/(递归)、.zcode、.claude、README×2:唯一字样残留 = P3(plans/2026-11-02-main-dev-loop-skill.md:132);feat-done.sh 旧「记得推送」行已替换(grep 零命中);git-worktree-workflow.md 无旧字样但流水线枚举缺新步骤(即 P2)。

## 验证记录(亲跑;引用真实退出码)

- `sh /tmp/nn-probe/push-matrix.sh` → exit 0。[1] 改前 rc=0、只打「记得推送」、未推(origin=6d6bbe0 ≠ work=237bfa9);[2] 改后 rc=0、「⬆️ 已推送 develop → origin/develop (8191481)」、origin==work;[3] 分叉 rc=1(响亮)、origin 未被改写、本地 p3 合并保留;[4] SKIP_PUSH rc=0、「⏭ 跳过推送」、未推。
- 补充探针 `/tmp/nn-probe/push-matrix-extra.sh`(我自建,仅动 /tmp 沙箱)→ exit 0。X1 fetch 死路径:rc=1、「未推送:无法 fetch origin(离线或远端不可达)」+ 手动命令、合并保留本地;X2 fetch 正常而 push URL 死路径:rc=1、git 两行 `fatal:` 在 stderr 可见、未推、合并保留。
- 人工对齐命令(真分叉态,沙箱):`git merge origin/develop` → 合并提交 73812d5 创建(pre-merge-commit 放行);`git push origin develop` → rc=0,origin==local==73812d5。
- `sh scripts/lint.sh` → exit 0(仅存量 warning,error 级零);`sh scripts/doc-audit.sh` → exit 0;`sh scripts/check-arch.sh` → exit 0;`sh scripts/affected-tests.sh` → N/A(无 Swift/pbxproj 改动)。
- 铁律遵守:零真仓库 git 状态变更(探针只读 clone 真仓库、变更全在 /tmp/nn-push-probe* 沙箱);未跑 build.sh(沙箱 feat-done 全带 NEMONOTCH_HOOK_DEBUG=1);未改任何文件(本记录由派发方落盘)。

## 流程备注

本分支触及「钩子脚本」= AGENTS.md 列的高爆炸半径面;挑战者第二席按口径在停顿那一拍由主对话提议加开,不属本评审职权,仅记录:本轮单席评审,以六结局实证 + 门禁三绿补强。
