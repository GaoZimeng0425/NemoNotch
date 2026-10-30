# Code Review — feature/media-badge-ca

Reviewer: independent review subagent (Claude, fresh context; did not author the change)
Date: 2026-10-30
Reviewed-Head: a2464c7
Verdict: APPROVED
Scope:  4 files changed, 384 insertions(+), 64 deletions(-)

```
AGENTS.md
NemoNotch/Helpers/MediaLayerViews.swift
NemoNotch/Helpers/MediaViews.swift
NemoNotchTests/EqualizerKeyframesTests.swift
```

## Findings

### 复审(a2464c7,2026-10-30)

首轮(a1d798f)判 CHANGES_NEEDED;作者补提交 `a2464c7 fix: share one vinyl phase across disc instances`。逐条处置:

- **Finding 1 [P2] — 已解决。** 新增纯 `VinylClock`(`MediaLayerViews.swift:51-78`)作为全部唱片共享的唯一相位(`private static var clock`,NSView 子类即 MainActor 隔离,无并发问题);`applyClock()`(`:146-168`)暂停时摆静态角、播放时以 `spin.timeOffset = phase` 起转,入窗/播停变化都重新对齐。墨菲两端与每次重建的实例读同一相位,封面不再跳正。数学核对:播放时 anchor=相位 0 的媒体时间,暂停/恢复同一表达式 `anchor = now - anchor` 互逆,`setPlaying` 幂等(两端各报一次不重置)。证据:2 级(file:line 推导)+ 4 级(`VinylClockTests` 6 例;`sh scripts/mutate.sh … 'anchor = now - anchor' 'anchor = now' --only VinylClockTests` → 3 败 3 过,退出码 65,已恢复原文件)。未到 5 级:没在运行中的 app 里录屏看开合。
- **Finding 2 [P3] — 接受,延后。** 改后性能读数需要放歌的真实运行环境,作者承诺部署后在运行中的 app 采样。合并后请补记(主线程 `sample` 占比 / `NEMONOTCH_PERF=1` 的 `VinylDiscView.body` 频率);在此之前 AGENTS 条目里的「~23%」只是改前数字,不是改后结论。
- **Finding 3 [P3] — 接受,不改。** 变形中硬币位图拉伸仅视觉、交叉淡化掩盖,不阻塞。
- **Finding 4 [P3] — 接受,不改。** 均衡器几何参数只在创建时读;唯一调用点全传常量,属潜在坑。

**复审新发现:无。** 次要观察(不算 finding):`applyClock` 取相位用的 `CACurrentMediaTime()` 与动画实际 beginTime(事务提交时)差几毫秒,角度误差 <1°,不可见。

复审验证:`sh scripts/affected-tests.sh` 选出 `EqualizerKeyframesTests` + `VinylClockTests`,12 过 0 败,退出码 0(`build/test.log`);`sh scripts/check-arch.sh` 退出码 0。4 级。

### 首轮(a1d798f)

1. **[P2] 每次开合刘海,唱片角度都会跳回 0(墨菲变形两端不再同相)** — `NemoNotch/Helpers/MediaLayerViews.swift:57-67,119-133`(配合 `BadgeIconView.swift:45-53` 与 `OverviewTab.swift:312-322` 的 `matchedGeometryEffect`)。
   旧实现角度由挂钟推导(`angle(at: context.date)`),收起态硬币与展开面板唱片是两个实例但任一时刻同角度,飞入/飞出的墨菲在转动中连续。新实现每个 `VinylSpinnerView` 实例从 `speed = 0`、`timeOffset = 0`、`fromValue = 0` 起步,角度是**实例局部状态**;收起↔展开每次都卸载旧实例、新建新实例(`NotchView.swift:148-160` 条件挂载),所以放歌时每次开/合刘海封面都会从任意角度跳回正上方,且变形中两端角度不一致。
   修法建议(小改):相位放在实例外——例如静态共享「最后角度/时间基」,新实例创建时以它为 `timeOffset` 起点;或播放时按 `CACurrentMediaTime()` 对 period 取模播种 beginTime(恢复挂钟同相语义),暂停时把保持的角度写回共享相位。
   证据:2 级(file:line 推导,CA 时间语义:新层 speed 0 + timeOffset 0 + fromValue 0 ⇒ 创建时角度必为 0)。未到 5 级——没有在运行中的 app 里录屏复现;作者可直接放歌开合刘海确认。

2. **[P3] 性能结论只有「改前」数字,没有「改后」实测** — commit `a1d798f` 提交信息与 `AGENTS.md:148` 新条目。
   提交信息引用了改前 ~23% 单核(410/1504 样本)的采样,但没有改后同条件的采样/PerfProbe 读数;AGENTS 新增的规则因此建立在「推断会降下来」上。按证据纪律,这是一次以性能为唯一动机的改动,改后读数应写进提交或评审记录(如 `NEMONOTCH_PERF=1` 下 `VinylDiscView.body`/`AudioEqualizerView.body` 频率 + `sample` 主线程占比)。证据:2 级(读提交信息与 diff)。

3. **[P3] 展开↔收起变形中,硬币位图被拉伸放大** — `MediaLayerViews.swift:44-48,64,106-117`。
   面按 `faceID.size`(20pt)光栅化一次,`matchedGeometryEffect` 插值帧时 `layout()` 把同一张 20pt 位图 `resizeAspect` 拉到面板尺寸,飞行中会糊;对端(面板实例)按自身尺寸光栅化,交叉淡化可能掩盖大半。证据:2 级;仅视觉,不阻塞。

4. **[P3] `EqualizerBars` 只在 make 时读几何参数** — `MediaLayerViews.swift:177-184`。
   `barCount`/`maxHeight`/`barWidth`/`spacing` 变化后 `updateNSView` 不会重建,条数与高度保持旧值。现唯一调用点(`BadgeIconView.swift:57-62`)全传常量,属潜在坑;可在 update 中比对后重建或在注释写明「几何参数视为常量」。证据:2 级。

### 已核对、无问题
- hit-testing:两个 NSView 均 `hitTest → nil`,符合 Edge Bar 坑 1(NSViewRepresentable 吃点击)。2 级。
- 挂载纪律:收起态徽章仍条件挂载(`NotchView.swift:148-160`),无 opacity 式隐藏;CA 动画随视图销毁。2 级。
- 暂停/恢复:speed/timeOffset/beginTime 写法即 Apple QA1673 标准模式,暂停保相位、恢复续转;`updateNSView` 先于入窗调用时顺序也成立。2 级。
- 均衡器:各条独立随机轨道、首尾为 rest 无缝循环,竖直居中锚点与旧 HStack 居中一致;停播 removeAnimation 即回 rest 与旧行为(无动画回 2pt)一致。2 级。
- Swift 6 并发:全部在 NSView/NSViewRepresentable 的 MainActor 上下文,`ImageRenderer` 主线程调用,无跨隔离。2 级。
- 测试:`sh scripts/affected-tests.sh` 选出 `EqualizerKeyframesTests`,6 过 0 败,退出码 0(日志 `build/test.log`)。4 级。
- 鉴别力:`sh scripts/mutate.sh MediaLayerViews.swift 'heights: [rest] + peaks + [rest]' 'heights: peaks + [rest, rest]' --only EqualizerKeyframesTests` → 变红(1 败 5 过,xcodebuild 退出码 65),文件已恢复。4 级。
- 旧 PerfProbe 键 `VinylDiscView.frame`/`AudioEqualizerView.animTick` 全仓无其他引用(rg)。4 级。

### 教训候选
- `MediaLayerViews.swift:57-67`:把 SwiftUI 的「从挂钟推导值」改成 CA 实例动画时,**状态从全局变成了实例局部**——凡是同一视觉在多处实例化(matchedGeometry 两端、多屏各一份)的动画,迁移 CA 前先问「两个实例要不要同相」,要就把相位放实例外。可写进 AGENTS 坑总目录「常驻动画一律 CA」那条的附注。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:EqualizerKeyframes 测试以种子 RNG 调纯函数断言字面形状;mutate.sh 注入变异变红(4 级)。VinylSpinner 无测试——AppKit/CA 集成,按规则跳过
- [x] **证据纪律**:单测/变异 4 级;改后性能实测接受延后至部署后(Finding 2,已记录待补)
- [x] **Swift 6 并发**:全 MainActor,无回调线程/Sendable 边界
- [x] **最小改动**:改动限于两视图内部与一条 AGENTS 坑条目;调用点零改动
- [x] **错误路径**:N/A(无可失败 I/O;`ImageRenderer` 返回 nil 时面为空,无崩溃)
- [x] **坑总目录对照**:对照 SwiftUI 渲染节(条件挂载、TimelineView 逐帧)、Edge Bar 坑 1/3(hit-testing、CA 子层 hitTest→nil)——均符合
- [x] **教训候选**:见 Findings 尾部
- [x] **文档同步**:AGENTS.md 已加 CA 常驻动画条目;用户可见行为无新增,README 无需改

## 评审方法提示(给评审会话)

在 worktree 里:`git diff e49f7fc80db2355b2f98785a189afa5ff5ddfcba...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
