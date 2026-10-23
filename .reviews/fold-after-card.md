# Code Review — feature/fold-after-card

Reviewer: ZCode 独立评审子代理（judge ≠ author，未参与开发）
Date: 2026-10-23
Verdict: APPROVED
Scope:  5 files changed, 129 insertions(+), 3 deletions(-)
Branch head at review: ee93c2f（= 修复提交，评审期间分支未被重写）

```
AGENTS.md
NemoNotch/Notch/EdgeBar/EdgeBarAutoCard.swift
NemoNotch/Notch/EdgeBar/EdgeBarController.swift
NemoNotch/Notch/EdgeBar/EdgeBarMetrics.swift
NemoNotchTests/EdgeBarAutoCardTests.swift
```

## Findings

- **[P3] waitForCard 重查无去重/代际守卫**（NemoNotch/Notch/EdgeBar/EdgeBarController.swift:305-313）：0.2s 等待窗内每次 refresh 都各排一个 `asyncAfter`（同一绝对截止 ≈ `cardGoneBy`），到点齐发、各跑一次全量 `refresh()`。有界（≤ 窗内事件数）且 `refresh()` 幂等，首个到点者 close 后其余因 `autoOpened=false` 走 standDown——无活锁、无级联推迟（每次都排向同一 deadline，不会越推越远）。但与同文件 `EdgeBarHoverIntent`/`EdgeBarRowSwitch` 的 generation 纪律（EdgeBarIntent.swift:74-77）不一致，属健壮性备注，不拦合并。
- **[P3] `closeBar()` 会落一个惰性 stale `cardGoneBy`**（NemoNotch/Notch/EdgeBar/EdgeBarController.swift:669-675, 718-720）：`closeBar()` 先 `autoOpened = false` 再 `deselect()`（此刻 `isOpen` 仍真、卡仍在 → 记 `cardGoneBy`），随后才 `isOpen = false`。实测惰性：closePlan 首个 guard 即 `autoOpened`，且 0.2s 内重新自动开栏必然因 approval/alert 到达 → standDown；最坏影响 = 病态序列下一次 ≤0.2s 的自动收起延后。可接受，记录在案。
- 无 P1/P2。

## 复验记录（全部真跑，退出码为准）

- 红→绿可重放：worktree 内 `git checkout 891a65e -- <EdgeBarAutoCard.swift> <EdgeBarAutoCardTests.swift>` 后 `sh scripts/test.sh --only EdgeBarAutoCardTests` → **退出码 65，恰好 `closePlanWaitsForTheCardToLeave` 1 例失败（通过 15）**，与红测 commit 信息引用的输出逐字一致（红测 commit 的 closePlan 签名齐全、`waitForCard` case 已在枚举中，可编译，body 只有 guard + `return .close`——红是真红不是编译错）。恢复经 `git restore --staged --worktree`（注意 `git checkout <commit> -- <path>` 会写 index，仅 `git checkout -- .` 不够），恢复后 `git status` 仅剩本记录、HEAD 仍 ee93c2f。
- 绿：HEAD 上 `sh scripts/test.sh --only EdgeBarAutoCardTests` → **退出码 0，通过 16 · 失败 0**。
- 全量：HEAD 上 `sh scripts/test.sh` → **退出码 0，通过 527 · 失败 0**（与修复 commit 声明一致）。
- 变异：`sh scripts/mutate.sh NemoNotch/Notch/EdgeBar/EdgeBarAutoCard.swift 'now < gone' 'false' --only EdgeBarAutoCardTests` → **退出码 0**（变异被抓住：失败 1 · 通过 15，文件自动恢复）。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**：4 个新测试覆盖 close/standDown×4/wait/过期-close 全分支；把 wait 分支变异掉套件即红（上列变异复跑），被测若只会返回默认值则 close/standDown 用例必挂——有牙。ulp 容差断言（0.001）有注释说明动机。
- [x] **证据纪律**：两份 commit 信息均到第 4 级（脚本 + 退出码 + 失败用例名）；本人复跑全部对上。
- [x] **Swift 6 并发**：`EdgeBarController` 为 `@MainActor`（:8-10）；`asyncAfter` + `MainActor.assumeIsolated` 与同文件 pressFeedback（:936-941）及 `EdgeBarIntent`/beat timer 既有模式一致；闭包 `[weak self]` + `guard self.isOpen` 防重入；dispatch main queue 即 main actor executor，假设成立。
- [x] **最小改动**：5 文件全部可追溯到 bug；决策提纯进 `EdgeBarAutoCard.closePlan`（与既有 `plan` 同居、纯函数可测），controller 只做接线 + `cardGoneBy` 记录；新常量 `cardRemovalHold = 0.2` 放 `EdgeBarMotion` 与同类时长为邻。无顺手改动。
- [x] **错误路径**：closePlan 的 `.standDown` 显式 no-op；scheduled 闭包对 bar 已关（`!isOpen`）早退；UTestMode/拖拽由 autoCard 顶部 guard（:275）覆盖，重查闭包经 `refresh()`→`autoCard` 同样被拦。
- [x] **坑总目录对照**：Edge Bar 不变量 (1)-(5) 均未被破坏——`holdsBarForAlert`/`holdsBarForApproval`/`reclaim`/autoAlert 全未动；「tracking area 重建 exit 要对着光标实测」坑与重查时读新鲜 `pointerOnBar()` 一致；「拖拽帧纪律」未触及。
- [x] **文档同步**：AGENTS.md 不变量 (6) 与实现逐点对上（deselect 记录条件 `isOpen && cardRect != nil`、0.2s、closePlan 路由、hover 0.25s 宽限未动）；bug 修复不改 README 功能描述，N/A。

## 行为保持核对（旧条件 vs closePlan）

旧：`if autoOpened, !approvalWaiting, alerts.isEmpty { guard !pointerOnBar() else { return }; close }`——close 块是 autoCard 末语句，`return` 与落空等价。新 closePlan 的 guard 是同一合取（`alertsPending: !alerts.alerts.isEmpty` 恰为旧 `.isEmpty` 的否定），`cardGoneBy == nil` 时直接 `.close`，逐输入等价。审批答完路径不调 `deselect`（行还在、选择被 revalidate 保留，`cardGoneBy` 保持 nil）→ `.close`，行为不变。`pointerOnBar()`（:383-387）从「条件成立才调」变为每次求值：纯读（window 鼠标位置 + convert + contains），无副作用，成本可忽略。时序数字核对：卡淡出 `cardOut=0.14` < `cardRemovalHold=0.2` < 栏折 `body=0.24`，且 hover 离开宽限 `closeTolerance=0.25` 未动——所有收起路径均有序于卡退场之后。
