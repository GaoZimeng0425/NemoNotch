# Code Review — feature/harden-review-freshness

Reviewer: ZCode 独立评审子代理(GLM;judge ≠ author,未参与开发)
Date: 2026-11-02
Reviewed-Head: 50a0e18
Verdict: APPROVED
Scope: 4 files changed, 51 insertions(+), 14 deletions(-)

```
.githooks/freshness.sh
AGENTS.md
NemoNotch/Services/AppActivator.swift
scripts/review.sh
```

## Findings

- [P3] NemoNotch/Services/AppActivator.swift:273 — `onScreenWindowCount` 的过滤逻辑(pid/layer==0/≥200×150/NSNumber cast)是纯逻辑,「无便宜单元测试目标」的说法不完全成立:抽一个接受 `[[String: Any]]` 的内部函数(如 `normalWindowCount(_:)`)即可用合成窗口字典做判别性测试(Mail 33px 辅助窗 + 800×600 真窗 + layer-3 + 他 pid → 期望 1)。修法:下轮顺手提取并补一条 Swift Testing 用例(可过 `sh scripts/mutate.sh` 验牙)。非阻塞:log-only 路径,零行为变更。
- [P3] scripts/review.sh:118 — 只认三种已填值后,拼写偏离的 Verdict 行(如小写 `approved`)不再受保护,重跑本脚本会把整份记录洗回空白模板——与注释里「曾把填好的 CHANGES_NEEDED 洗掉」同族的窄口子。修法(可选):regex 不匹配但 `^Verdict:` 存在且非 `Verdict: (填` 时,提示「Verdict 行存在但非标准值」退出而不重生成。实际风险窄(feat-done 门禁只认 `^Verdict: APPROVED`,畸形记录本就不可合并;记录由主对话落盘)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:本分支无新增测试。freshness/review 为 shell 行为,仓库无 shell 测试基建——探针 + 本评审沙箱复现代替(见下「验证记录」);verifyFrontmost 三态分支需真激活,无便宜目标;唯一可测面是 P3-1 的窗口过滤纯逻辑,已列 P3。
- [x] **证据纪律**:c37703e 提交信息带前后探针 rc(第 4 级),且本评审在独立沙箱原样复现(red→green 可重放,/tmp/nn-fresh-verify 留档);50a0e18 的最终确认声明为「部署后日志出现 `took; visibleWindows=N`」(第 5 级,待部署——交付物即该日志行,可接受)。
- [x] **Swift 6 并发**:`asyncAfter` 闭包只捕 pid/name(Sendable 标量);`onScreenWindowCount` nonisolated static、C API 主线程调用;CGWindowList 不读 `kCGWindowName`、不过 TCC(与 AGENTS.md PermissionFlow 节口径一致)。lint 0 + AppActivatorTests 10/0 过。
- [x] **最小改动**:三处修复各 ≤ 数行、注释带 why 指针;AGENTS.md 仅一行,且该行同时修复上一 feature 遗留的失效口径「激活统一走 bringForward」(commit message 有交代,属文档同步职责内);无顺手改动。
- [x] **错误路径**:install 失败 → ❌ 手动指引(路径同改为主检出);review.sh 分流明确;AppActivator 三态各有日志无吞错。verifyFrontmost 成功路径新增一行 .info(每次点击一行,非轮询,不违反日志纪律)。
- [x] **坑总目录对照**:窗口/换窗坑未触碰;CGWindowList 用法与拖拽授权节「窗口服务查询不过 TCC」一致;日志节「点击触发非轮询」合规。
- [x] **教训候选**:见下。
- [x] **文档同步**:AGENTS.md 已同步(AGENTS.md:119);README/README_CN 不涉(内部工具与诊断日志,无用户可见功能面)。
- [x] **工作流机制清场**:全仓 grep 过——旧重装话术「正在重新安装(sh .githooks/install.sh)」无残留;「激活统一走 bringForward」旧口径已清(仅 AGENTS.md:119 新分述);docs/git-worktree-workflow.md 无涉;docs/superpowers/plans/2026-11-02-main-dev-loop-skill.md:16,100 对「已填不覆盖」的描述在新行为下仍准确。

## 验证记录(全部本评审亲跑,退出码为证)

- `sh scripts/lint.sh` → exit 0;`sh scripts/doc-audit.sh` → exit 0;`sh scripts/check-arch.sh` → exit 0。
- `sh scripts/affected-tests.sh f455caf…` → 选中 AppActivatorTests,10 过 0 败,exit 0(build/test.log)。未重跑全量:派发方已跑(627/0,test-head.txt=50a0e18=当前 head),feat-done 门禁会因锚点命中短路,证据链完整。
- 症状 2 自然验证:空白模板连跑两次 `sh scripts/review.sh harden-review-freshness`,两次均「📝 模板已生成」RC=0(改前会误报「已填不覆盖」);regex stdin 探针:占位行(含内嵌「Verdict: APPROVED」引文,行首锚保护)不命中,`CHANGES_NEEDED`/`无法验证`/`Verdict:APPROVED`(无空格)均命中。
- 症状 1 沙箱复现(临时仓库 /tmp/nn-fresh-verify:真实 freshness.sh/install.sh + 桩 hook,main=v2 / worktree=v1,从 worktree cwd 调用,零碰真仓库):旧版(f455caf)run1 rc=1 → run2 rc=1、已装副本=worktree v1(死循环原样复现);新版(HEAD)run1 rc=1(已装副本变 main v2)→ run2 rc=0(环破)。与 c37703e 提交信息探针声明逐项吻合。
- 症状 3:代码级核对(verifyFrontmost 仅 openApp:213 / bringForward:239 两个既有调用点,零改调用方;全仓 grep 无其他引用)+ AppActivatorTests 过;运行时日志行验证待部署后任意 toast 点击(作者声明同一验证方式)。
- 披露:本评审按派发方指示跑了两次 review.sh,重生成了 .reviews/harden-review-freshness.md 空白模板(untracked,即症状 2 的自然验证);除此之外零文件改动、零 git 状态变更、未跑 build.sh。沙箱目录 /tmp/nn-fresh-verify 留档供复放。

## 教训候选

- .githooks/freshness.sh:50 — 「检测与自愈动作必须吃同一份真相源」:比对用主检出源、安装却随 cwd 定根,自愈就变成假自愈(已带 why 注释;不易 lint 化,建议 experience-playbook 收录该判据,或 guardrail-backlog 评估「自愈脚本禁止依赖 cwd 的相对 git 解析」类静态检查的可行性)。
- scripts/review.sh:118 — 「保护性判定锚定到值而非前缀」:`^Keyword:` 型 grep 对模板占位行天然误报,feat-done.sh:141 的 `(填` 反向守卫与本脚本的正向白名单是同一课的两种写法,后续新增门禁 grep 时照正向白名单写。
