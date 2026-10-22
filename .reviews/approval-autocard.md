# Code Review — feature/approval-autocard

Reviewer: ZCode 独立评审子代理(GLM-5.3;未参与本 feature 开发,judge ≠ author)
Date: 2026-10-22
Verdict: APPROVED
Scope:  8 files changed, 299 insertions(+), 3 deletions(-)

```
AGENTS.md
NemoNotch/Notch/EdgeBar/EdgeBarAutoCard.swift
NemoNotch/Notch/EdgeBar/EdgeBarController.swift
NemoNotch/Notch/EdgeBar/EdgeBarIntent.swift
NemoNotch/Notch/EdgeBar/EdgeBarWindow.swift
NemoNotchTests/EdgeBarAutoCardTests.swift
README.md
README_CN.md
```

## Findings

无 P1 / P2。以下 P3 均不阻塞合并(记录在案,作者自行取舍):

- **[P3] 滞留的 `autoOpened` 产生一次假 "Auto-closed" 日志** — `EdgeBarController.swift:240-245`。`autoOpened` 只在 `.entered`(451-454)或自动关闭路径清零;特性开关中途关/开(refresh 的 disabled 分支 :158-163 不清)、或光标经 keep-installed 区域进入后 exit 关栏(无 `.entered` 发生)都会让它活到下一次 refresh,随后 `hover.closeNow()` 对已关的栏 no-op、却照打 "Auto-closed the bar: no approval waiting"。纯日志噪音;可在 `closeBar()` 或 disabled 分支顺手清 `autoOpened`。
- **[P3] 拖拽期间到达的审批边沿被静默消费** — `EdgeBarController.swift:222` 的 `guard !isDragging` 连同 refresh 已把 `previous` 推进(:170-173):拖拽中开始的审批此后永不自动开卡(环照常显琥珀)。拖拽中弹卡确实更糟,取舍合理,但行为与文档"会话进入 waitingForApproval 的那一拍"表述存在缝隙,值得知道。
- **[P3] 未决的 row dwell 可在 ~0.15s 后顶掉自动选中的卡** — `EdgeBarController.swift:536` 的 `select()` 不取消 `rowSwitch`;`EdgeBarIntent.swift:117-136` 的 dwell 项带着旧 `row` 照发。仅当光标确实静止停在开着栏的另一行上才发生,与"光标在栏上即拥有它"的既有语义一致,非缺陷。
- **[P3] `keep([])` 修复与控制器接线无直接测试** — 12 个新测试只覆盖纯决策核。`PointerRelay.keep` 虽可直接调用,但 `inside` 无法经公开 API 填充(`entered` 私有),回归测试需要一个小缝。按仓库"只测纯逻辑"惯例可接受;纯核已变异验证有牙(见下)。

### 七个重点问题的结论(全部走代码路径验证,非推断)

1. **观察回路:无。** `refresh()` 唯一入口是 `observe()`(`EdgeBarController.swift:144-155`);`withObservationTracking` 只注册 `store.sortedSessions`/`aiStatusFabEnabled`/`usageQuota.quotas`(:145-148)。autoCard 写的是控制器自身可观察属性(isOpen/selectedRow/cardSlot/scrollOffset),不在被跟踪集合里;SwiftUI 失效在后续 runloop turn 落地,`cardFrameChanged → updateTrackingAreas → keep` 链无路回 `observe()`。`openBar` 里的 usage Task(:511-515)稍后改 quotas → 多一次 refresh,服务端 60s 节流,有界。
2. **openNow → onChange → openBar 同步链里 keep 不再误发 .exited:修复完备。** `wasInside` 在 `formIntersection` **之前**取值(`EdgeBarWindow.swift:259-260`)是必须的(交集后 inside 必空)。时序:`hover.openNow()`(:230)→ `onChange` 同步 `openBar()` → `isOpen=true` → `updateBodyRect` → `updateTrackingAreas` → `relay.keep(光标所在区域)`;光标不在栏 → `keep([])`,`inside` 本就为空(从未 enter)→ 新代码不发 `.exited`。旧代码会 → `want(false)` → 0.25s 后把刚开的栏关掉——正是本修复针对的 bug,复现路径与提交信息一致。
3. **合成 pointer(.moved) 无非预期选择。** `openBar` 的合成 move(:520-524)是既有代码;自动开栏路径下它在 `select(id)` **之前**同步执行(selectedRow 尚 nil),光标不在栏时 `isOverHead`/`slot`/`usage.provider` 全部几何判 nil(`EdgeBarMetrics.swift:246-266` 的 x/y 界检查保证离栏点映射不落入行/头区域)。光标恰在展开带内时 dwell 选卡 = 既有"光标拥有栏"语义。
4. **reveal() 数学正确。** 按 `EdgeBarMetrics` 实数计算:`slotTop(i) − listTop = 30i + 5`(headTop 34 + headSize 34 + ringTopGap 18;listTop = slotTop(0) − 5)。未夹紧时 offset = 30s+5 把该行顶对齐 listTop(首行可见:top −5≥−0.5 ✓,bottom 25 ≤ listHeight+0.5 对一切 n≥1 ✓);夹紧时(n≥8, s≥n−7)offset = 30n−225,行顶相对 listTop ∈ [20,200],行底 ≤220 ≤ 225.5 ✓。n≤7 时 maxScrollOffset=0 且所有行本可见(30i+25 ≤ 30n+0.5),reveal 正确 no-op。`scroll(at:)` 手滚出界的行会 deselect(:812-815)是既有互补行为。
5. **select(id) 分支无冲突。** `decision.select` 只可能来自 `next.rows`(会话 id);usage 卡 id 是 `"usage:<provider>"` 前缀(`EdgeBarUsage.swift:155-163`),两个 id 空间不相交。`revalidateSelection()`(:185)先于 autoCard 跑,selectedRow 指向已消失行的情况已被 deselect,`selectedHoldsApproval` 不会误判。
6. **keep([]) 语义收窄无滞留开栏风险。** 新代码只在 `inside` 非空(光标被计为在栏上)时发 `.exited`。逐场景核对原靠 keep([]) 兜底的关栏路径:光标曾 enter(body 缩短把它留在栏外、区域移除无 mouseExited——`EdgeBarWindow.swift:224-225` 注释即 AppKit 行为)时 `inside` 均非空 → `wasInside=true` → 照发 .exited,语义保留。`inside` 为空且栏开着的唯一状态就是本次新增的自动开栏(其关栏由 autoCard + pointerOnBar 负责)——语义收窄面恰好等于新状态面。AppKit 对**移除**的区域不发 exit,故 keep 是唯一兜底,而它对非空 inside 的行为未变。
7. **Swift 6 隔离干净。** `EdgeBarAutoCard` 是纯静态枚举,仅从 `@MainActor` 的 refresh 调用;`SessionPhase`/`PermissionContext` 值不跨任务;`openNow` 经 intent 写状态,回调链全程 MainActor;既有 `MainActor.assumeIsolated` 模式未动。无新增 `@unchecked Sendable`/`nonisolated(unsafe)`(cookbook 更新规则不触发)。

### 坑总目录对照

未踩已知坑:无 repeatForever/opacity 隐藏/offset 定位;hover 仍走 tracking area + 几何解析(非激活面板坑);拖拽帧纪律经 `guard isDragging`(:222)绕开;自动开栏复用既有 openBar 路径,无手搓动画。新坑(`keep([])` 的 wasInside 条件)已写入 AGENTS.md「Edge Bar」节——文档对账门禁实跑通过。

### 错误路径核对

特性开关中途关(disabled 分支关栏+orderOut,autoOpened 残留→见 P3-1,无功能泄漏)→ 再开(首刷新自愈);拖拽中(autoCard 全跳过,见 P3-2);UITestMode(autoCard 入口 guard :222,UI-test 截图无自动开栏);window 为 nil(refresh 顶部 makeWindow :164-165 先于 autoCard);全部审批行随会话结束消失(rows 不含 → 自动关)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:有牙。变异验证 3 次(脚本 `scripts/mutate.sh`,文件均自动恢复):禁用审批分支 → 6/12 红(退出码 65);禁用 parked 分支 → 1/12 红;禁用先到先得守卫 → 1/12 红。若 plan 恒返默认 `Decision()`,6 个测试失败——被测代码返回默认值时套件不过。
- [x] **证据纪律**:本评审实跑:`sh scripts/test.sh --only EdgeBarAutoCardTests` → 12/12 通过、退出码 0(build/test.log);`sh scripts/lint.sh` → 退出码 0;`sh scripts/doc-audit.sh` → 退出码 0;变异 65×3。提交信息不含超出实际的验证声明。
- [x] **Swift 6 并发**:见重点问题 7;无新增跨隔离访问。
- [x] **最小改动**:8 文件全部可追溯到任务(纯决策 + 接线 + keep 修复 + 测试 + 三处文档);无顺手重构;`EdgeBarHoverIntent.openNow` 与 `closeNow` 镜像对称,必要新增。
- [x] **错误路径**:见上节;无吞错(日志 .info 记自动开/关与自动选卡,category "EdgeBar")。
- [x] **坑总目录对照**:见上节;新坑已登记 AGENTS.md。
- [x] **文档同步**:AGENTS.md「Edge Bar」+ README.md + README_CN.md 同一提交更新,doc-audit 通过。

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 4e3138fac553df413c9a447234f5dae7012d5a0e...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。

(评审注:任务书给的 base 哈希 `…4234f5a0e` 少了 4 个字符,实际 base 为 `4e3138fac553df413c9a447234f5dae7012d5a0e`,即 develop 侧 `4e3138f`;单一提交 `bf0efd7` 已全量评审。)
