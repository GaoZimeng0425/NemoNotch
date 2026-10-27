# Code Review — feature/notch-toast

Reviewer: independent code-reviewer subagent (fresh context; did not author this branch — judge ≠ author)
Date: 2026-10-27
Reviewed-Head: 4931983
Verdict: APPROVED
Scope:  13 files changed, 744 insertions(+), 207 deletions(-)

```
AGENTS.md
NemoNotch/Helpers/Constants.swift
NemoNotch/NemoNotchApp.swift
NemoNotch/Notch/CompletionFlashView.swift
NemoNotch/Notch/CompletionToastLayout.swift
NemoNotch/Notch/CompletionToastView.swift
NemoNotch/Notch/CompletionToastWindow.swift
NemoNotch/Services/CompletionFlashService.swift
NemoNotch/Services/CompletionToastQueue.swift
NemoNotchTests/CompletionToastQueueTests.swift
README.md
README_CN.md
docs/images/completion-flash.png
```

## Findings(第 1 轮,Reviewed-Head 4c6fc64 → CHANGES_NEEDED;第 2 轮复审见文末)

证据完备度声明:以下判断基于代码阅读(梯级 2–3)+ 单测实跑(梯级 4,见下);**未在运行中的 app 复现**(未跑 build.sh、未做多屏/悬停实机验证)。F1 的触发链是代码审阅推断。

测试实跑:
- `sh scripts/affected-tests.sh` → exit 0,「通过 17 · 失败 0」(CalendarDueDetectorTests + CompletionToastQueueTests 8 例)。**未包含 CompletionToastLayoutTests**(见 F2)。
- `sh scripts/test.sh --only CompletionToastLayoutTests` → exit 0,「通过 5 · 失败 0」(build/test.log 中 5 条 `CompletionToastLayoutTests/... passed`)。

- **F1 [P2] 悬停暂停可能永久卡住——疑似退出被判"仍在内"后没有复查**。`NemoNotch/Notch/CompletionToastWindow.swift:123-125`(`mouseExited` → `report(cursorInRow())`)与 `:115-116`(重建 tracking area 后 `report(cursorInRow())`)。光标测得仍在行内时不改 `hovering`,之后也**没有任何复查**。AppKit 已经发过 exit,认为光标在区域外,所以光标真正离开时不会再来 exit → `hovering` 一直是 true → `CompletionFlashService.setToastHover(true)` 不会撤 → 队列一直暂停,卡片永不到期(要等用户再悬停、再移出才恢复)。AGENTS.md「Edge Bar」已记录这种情况:"tracking area 重建时静止光标下会发出 enter+exit 对——exit 要对着光标实测才信;**另每 0.25s 复查**"。本分支照搬了"实测"那一半,漏了"复查"那一半。最常见的触发路径正好是本功能的核心交互:光标停在行上点 ✕ 关掉一张卡 → `layout` 变化 → `updateTrackingAreas` 在静止光标下重建 tracking area。修法:照 `EdgeBarWindow.swift:178-250` 的 `PointerRelay` 做法——exit 实测仍在内时记为 doubted,`asyncAfter(0.25)` 复查,直到真的离开或来了 enter;或者 `hovering == true` 期间挂一个 0.25s 的轻量复查。(补:`remove()` 里的 `setHover(false)`(`:293`)只在面板被拆时兜底,行一直在显示时兜不住。)
- **F2 [P2] feat-done 的单测门禁不会跑 `CompletionToastLayoutTests`**。`NemoNotchTests/CompletionToastQueueTests.swift:96` 在同一个文件里放了第二个 suite。`scripts/affected-tests.sh` 只选出 `CompletionToastQueueTests`(上面实跑输出:"选出测试类: CalendarDueDetectorTests,CompletionToastQueueTests"),所以点击/关闭命中几何的回归在合并门上没人守。修法:把 `CompletionToastLayoutTests` 挪到独立的 `NemoNotchTests/CompletionToastLayoutTests.swift`(一个文件一个 suite),然后重跑 affected-tests,确认被选中。
- **F3 [P3] 刷新过的卡会先被顶掉**。`NemoNotch/Services/CompletionToastQueue.swift:37-45`:同名就地刷新时卡片留在原来的下标(最旧那端),而溢出时 `removeFirst` 顶的是数组头。例子:A B C D 满载,A 刚刚刷新,E 到达时被顶掉的是 A——最新的信息反而先消失。建议:刷新时把卡挪到队尾(id 不变,SwiftUI 会把它动画到新位置),或者按 deadline 最早的来淘汰;再补一条单测钉住这个行为。
- **F4 [P3] 按 `name`(= `projectFolder`)合并,会把不同会话、甚至不同 CLI 并成一张卡**。`CompletionToastQueue.swift:37` + `CompletionFlashService.swift:64`:同一目录下的 Claude 会话和 Gemini 会话会合成一张卡,而 `CompletionFlashNames.merge` 不更新 `source`,于是可能出现螃蟹图标配 Gemini 的 model/tokens。旧版胶囊也是按名字合并,所以不算回归;但现在"一完成一卡"是用户明确要的,建议把键改成 name+source(或者用会话 id)。
- **F5 [P3] 注释和实际动画对不上**。`CompletionToastWindow.swift:190-191` 说面板多出的 16pt 是"Room under the cards for the transition's travel",但 `:158` 用的是 `.move(edge: .top)`,往上走,会被面板顶边裁掉,下方那 16pt 没用上。要么改注释,要么改成真正用到这段空间的动画。
- **F6 [P3] 点卡片的 ✕ 会顺带收起另一块屏上打开的刘海**。`EventMonitor` 的 local `leftMouseDown` 监听器也会收到 toast 面板上的点击,进而走到 `NotchCoordinator.handleMouseDown`(`NotchCoordinator.swift:408-412`)→ 点击位置在刘海内容区外 → `notchClose()`。同一块屏不会发生(那块屏的行在刘海打开时已经藏起来了)。影响很小,可以接受;想避免的话,可以在 `handleMouseDown` 里跳过落在 toast 面板上的点击。
- **F7 [P3] 证据纪律**:提交信息里没有任何测试或运行验证的记录(退出码、日志、截图都没有)。`--uitest --flash` 截图更新了 `docs/images/completion-flash.png`,算一份运行证据,但提交里没有提到。

核对过、没问题的部分(梯级 2–3):
- 窗口生命周期:没有调用 `close()`,`isReleasedWhenClosed = false`,只 orderOut 并从字典换掉引用。屏幕重配走 pending 标志 + `DispatchQueue.main.async` 推迟一个 turn(`:232-244`)。观察 Task 里只做 re-arm,窗口操作挪到了 main-queue block 里(`:223-228`)。行重新出现时窗口重建(具文窗口修复)。
- 定时器:全局只有一个 `toastExpiryTask`,按最早的 deadline 武装,`max(…, 0)` 防负数。被早唤醒时会以剩余时间重新武装,不会空转;暂停时没有 deadline,不武装。`hideTask` 的取消和重新调度路径正确。
- 点击与命中:面板非激活、`canBecomeKey == false`、`acceptsFirstMouse`。`hitTest` 与 `CompletionToastLayout` 同源(和 EdgeBar 是同一模式),绘制和命中用的是同一套几何。
- 刘海交互:`topGap = hitboxPadding + 4`,让开了刘海的悬停 hitbox(`NotchCoordinator.swift:56-58`)。刘海打开的那块屏会拆掉行面板,拆面板时清掉悬停。
- 多屏:每块屏一块面板,`hoveredScreens` 取并集。
- 单测判别力:队列和布局测试都用具体输入断言字面结果;被测代码全返回默认值时会失败(nil 的 deadline、nil 的 hit、错误的 minX 都会被抓到)。`panelWidth()==1144` 接近"钉手写常量",但它校验的是公式,可以接受。

### 教训候选

- `NemoNotchTests/CompletionToastQueueTests.swift:96` — **一个测试文件放两个 suite,第二个 suite 会被 affected-tests 静默漏选**(合并门上的假绿)。可以做成门禁:check-arch 加一条 B 档规则("新增的测试文件里出现第二个 `@Suite`/`struct …Tests` 就拦"),或者让 `affected-tests.sh` 按文件选出文件里所有 suite。
- `NemoNotch/Notch/CompletionToastWindow.swift:123` — **非激活面板里的 hover:"exit 要实测"和"0.25s 复查"必须成对出现**;只做实测、不做复查,会在重建 tracking area 时把悬停状态永久卡在"在内"。建议把 EdgeBar 的 `PointerRelay` 抽成共享件,供 toast 行复用,不要每个面板各写一遍。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:新增/改动的测试有鉴别力吗?——有(见上);但布局测试被 affected 门禁漏选(F2)
- [x] **证据纪律**:提交信息里的验证声明到第 4 级了吗?——没有,提交里没有验证声明(F7);本评审已实跑单测补到第 4 级,但没到第 5 级
- [x] **Swift 6 并发**:隔离标注正确?——控制器是 `@MainActor`;通知 block 里用 `assumeIsolated` 后再推迟;`nonisolated(unsafe) observer` 只在 deinit 里读,与既有 FlashWindow 写法一致
- [x] **最小改动**:每行都能追溯到需求(位置、时长、关闭按钮、横排、悬停暂停);删掉的旧胶囊常量和合并逻辑都是被取代的部分
- [x] **错误路径**:出错时日志会响(init/deinit、面板创建、重建都打了日志);没发现吞错
- [x] **坑总目录对照**:close() 纪律、屏幕重配推迟、具文窗口、非激活面板几何解析都对照过——唯独漏了 hover 的 0.25s 复查(F1)
- [x] **教训候选**:见上
- [x] **文档同步**:AGENTS.md「完成闪光 / Toast」、README、README_CN 已更新

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 7c5dd4318391d596487eddf04314d3890c2766eb...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。

## 第 2 轮复审(Reviewed-Head 4931983)

复审范围:`git diff 4c6fc64..4931983`(另含第 1 轮评审记录文件)。证据完备度:读代码(梯级 2–3)+ 单测与变异实跑(梯级 4);**仍未在运行中的 app 复现**悬停卡死(F1 原本就是推断,修复也只验证到代码与单测层面)。

实跑:
- `sh scripts/affected-tests.sh` → exit 0,「选出测试类: CalendarDueDetectorTests,CompletionToastLayoutTests,CompletionToastQueueTests」,「通过 23 · 失败 0」。build/test.log 中 toast 相关 14 条 passed(Queue 9 + Layout 5),没有 failed。
- `sh scripts/mutate.sh NemoNotch/Services/CompletionToastQueue.swift '<min(by: deadline)>' 'let stalest = toasts.indices.first' --only CompletionToastQueueTests` → exit 0,「变异被抓住:失败 1 个,通过 8」(内层测试退出码 65);文件已恢复,`git status` 干净。

逐项结论:
- **F1 已关闭**。`CompletionToastWindow.swift:143-158`:从不在内转为在内时启动 0.25s 重复 `Timer`,每次都用实测的 `cursorInRow()` 重报;转为不在内时 invalidate。所以一次被误判的 exit 最迟 0.25s 内就会被纠正,不会再永久暂停。生命周期:`report` 有 `inside != hovering` 守卫,不会叠出两个 timer;`remove()`(`:313-319`)先 `stopHoverTracking()`,再 `setHover(false)`。面板的三条拆除路径(屏幕变化重建、刘海打开、清空后 hideTask)都经过 `remove()`。并发:timer 用 `scheduledTimer` 挂在主 runloop 上,block 里的 `MainActor.assumeIsolated` 成立,`[weak self]` 不会让视图多活。
- **F2 已关闭**。布局测试移到了独立文件 `NemoNotchTests/CompletionToastLayoutTests.swift`,affected-tests 已经选中它(见上)。
- **F3 已关闭**。`CompletionToastQueue.swift:44-47` 改为淘汰 deadline 最早的卡;deadline 相同时 `min(by:)` 取第一个,原来的 `capacityEvictsOldest` 照常通过。新测试 `refreshedCardSurvivesEviction` 用变异验证过有鉴别力(见上)。
- **F5 已关闭**。入场动画改成 `.scale(0.92, anchor: .top)`,在面板内缩放;面板高度改为 `cardHeight + 2`。行顶的屏幕位置没变(frame 的 y 用 panelHeight 推算,顶边仍是 `maxY - notch - topGap`),和刘海 hitbox 之间的间隙不受影响。
- **F4 接受(范围外)**。按 name 合并在本分支之前就存在,旧版胶囊也一样,不是回归。建议另开一个 follow-up,把键改成 name+source 或会话 id。
- **F6 接受**。影响很小:只有另一块屏的刘海开着时才会发生,收起刘海也是可以撤销的结果。
- **F7 已关闭**。第 2 轮的提交信息写明了 test.sh 的退出码、用例数和变异结果。

第 2 轮新发现:
- **R2-1 [P3,不阻塞]** 复查 timer 挂在 `.default` runloop 模式,鼠标按住拖动(事件跟踪模式)期间不会触发,松手后恢复。这对悬停语义无害,只是记录在案。
- **R2-2 [P3,不阻塞]** `CompletionToastHostingView` 没有在 deinit 里 invalidate timer,完全靠 `remove()` 的纪律。现在所有拆除路径都经过 `remove()`;如果以后有人绕过它直接丢掉 host,`[weak self]` 能防住崩溃,但 runloop 上会留一个每 0.25s 空转的 timer。可以加一道保险:`viewWillMove(toWindow: nil)` 时调 `stopHoverTracking()`。

第 2 轮判决:**APPROVED**。两个 P2(F1、F2)和 P3 的 F3、F5 都已关闭并经过实跑验证;剩下的 F4、F6、R2-1、R2-2 都是 P3,不阻塞合并。

### 教训候选(第 2 轮补充)

- 第 1 轮的两条仍然成立。F2 的修法是手工拆文件,"一个测试文件只放一个 suite"还没变成门禁,建议按第 1 轮的提议落进 check-arch 或 affected-tests。
