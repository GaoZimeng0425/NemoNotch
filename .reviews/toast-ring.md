# Code Review — feature/toast-ring

Reviewer: independent reviewer subagent (Claude, fresh context; did not author this branch)
Date: 2026-10-28
Reviewed-Head: 7d85d3d
Verdict: APPROVED
Scope:  第一轮 741959a..aea90af;复审 aea90af..60575c5、7d85d3d(54f8792 CA 环、cf90509 截图、60575c5 边栏右侧左对齐)

```
AGENTS.md
NemoNotch/Helpers/Constants.swift
NemoNotch/Notch/CompletionToastView.swift
NemoNotch/Notch/EdgeBar/EdgeBarMetrics.swift
NemoNotch/Notch/EdgeBar/EdgeBarView.swift
NemoNotchTests/EdgeBarMetricsTests.swift
README.md
README_CN.md
docs/images/completion-flash.png
```

## Findings

### 三审(head 7d85d3d)

- [P2→已解决] 7d85d3d 只改两处文字(AGENTS.md:117、CompletionToastView.swift:124-125,`git diff 60575c5..HEAD` 无其他改动):两批 bench 原始数据 12.80/17.87/11.70 与 10.45/13.50/12.04 都写明了,区间 10.5–17.9% 与这六个数一致(10.45 取一位小数四舍五入)。第一批此前没有任何记录，现在只有作者自述(梯级 1),但已在手册里摆出原始值、标明是隔离 bench,读者能看出证据的硬度。可以接受。
- 其余 P3 维持原判，协调者表示会向用户说明:停靠右侧也改了、名字离环的空隙、入场缩放与渲染服务器代价未目测/未测。

### 复审(head 60575c5)

- [已解决] 第一轮 P2(TimelineView 环 CPU 无实测):54f8792 改为 Core Animation(CompletionToastView.swift:126-216),提交信息带隔离 bench(4 卡,getrusage 20s×3:TimelineView 10.45/13.50/12.04%,CA 0.00/0.00/0.02%)。按协调者说明,这些数字是 bench 的第 4 级、不是真 app 的;提交里已如实写明「Render-server cost not measured」。可以接受。
- [P2→已解决于 7d85d3d] AGENTS.md:117 与 NemoNotch/Notch/CompletionToastView.swift:124 — 都写「4 卡实测 12–18% 单核」,但 54f8792 提交信息里唯一的实测是 10.45 / 13.50 / 12.04%(≈10–14%)。手册里一条「别改回」警告挂着一个证据链里找不到的数字;把两处改成提交里的实测值(或把 18% 那次的测量补进记录)。
- [P3] CompletionToastView.swift:205 — 只在 `viewDidMoveToWindow` 读一次 Reduce Motion;卡片在屏期间切换该设置不会生效(最多 5 分钟,影响很小)。
- [P3] CompletionToastView.swift(CA 环)— 卡片入场是 SwiftUI `.scale(0.92)` + opacity transition(CompletionToastWindow.swift:183),环现在是平台视图;transition 期间环能否跟随缩放未目测(只有截图,是静态终态)。如入场时环与卡片错位,把环改成从卡片自己的层取 transform。
- [P3] 渲染服务器侧代价未测(提交已自报),乘屏数后 WindowServer/GPU 占用仍是未知量;AGENTS.md 的措辞「app 进程近乎零 CPU」范围正确,未夸大。
- [P3] 60575c5 是否贴合需求 —— 实现以 `side == .left` 分支(EdgeBarView.swift:388),所以**停靠在右边**的栏和**浮在右侧的胶囊**都改成左对齐。用户原话说的是「胶囊在右边时」,"也"字暗示与左侧一致,合理推断覆盖两种形态;但停靠右侧也一起变了,汇报时要明说。
- [P3] 60575c5 会不会把文字推出展开的 body 或被裁 —— 结论:**不会越界,也不会无谓截断**(第 2 级,对照代码):列宽 `namesColumnWidth = openWidth − lead − nameInset`(EdgeBarMetrics.swift:104-106),label 从环一侧偏移 lead 后向远端伸展 lead+列宽 = openWidth − nameInset,恰止于 body 远端内侧 nameInset;`openWidth(of:)`(EdgeBarModel.swift:222-240)≥ `openWidth(namesWidth: min(widest, nameMaxWidth))`,所以列宽 ≥ 最宽名字/状态行(上限 210,超出才 tail 截断,与之前一致);开合与 openWidth 变化期间内容被 body 的动画形状裁切(EdgeBarView.swift:48-55 `bodyContent` 的 clipShape + `.animation(value: openWidth)`;浮囊同,:180-190),所以开合中途也画不出 body 外。`max(0, …)` 防负宽。
- [P3] 60575c5 的视觉副作用:列锚在 body **远端**而不是贴环——当 body 被用量块、summary 行或浮囊长度撑宽(EdgeBarModel.swift:240 取 max;EdgeBarController.swift:510-513 浮囊取 capsuleLength)时,右侧名字会离各自的环很远,中间留一大片空;用量读数开着时才落地会让整列名字横移(有动画,不是瞬跳)。这是"左对齐"的一种合理解读,另一种是列宽取最宽名字、贴环左对齐。没有真机截图(提交无验证声明,梯级 2),建议给用户看一张「右侧 + 用量块展开」的截图确认。
- [P3] 测试 EdgeBarMetricsTests.swift:66-74 有鉴别力:mutate.sh 去掉 `- nameInset` 后测试变红(exit 0,1 失败)。

### 第一轮(head aea90af,保留作证据链)

- [P2→已解决] CompletionToastView.swift:143 — TimelineView 30fps 常驻环无 CPU 实测(见上)。
- [P3] 全仓 `sh scripts/lint.sh` exit 1 的唯一 SwiftFormat 错误是 NemoNotch/Services/HookInstaller.swift:338 trailingSpace;该文件相对 base 741959a 字节未变,属既有问题,与本分支无关。
- [P3] 5 分钟时长的文档同步(README / README_CN / AGENTS.md)到位;CompletionToastQueueTests 用注入时长,改常量无需新测试。

### 教训候选

- 判据:**凡拉长常驻可见时长的改动,要连同该面上所有持续动画一起重估 CPU**(时长 × 帧率 × 屏数相乘)。本分支实证:SwiftUI TimelineView 4 个小环 ≈ 12% 单核 vs Core Animation ≈ 0%——已写进 AGENTS.md。可门禁化:check-arch B 档拦新增 `TimelineView(.animation`,需 `// fence: allow` 显式豁免。
- 判据:**手册里引用的实测数字必须能在提交信息/评审记录里找到原始数据**(本次 12–18% vs 10–14%)。

## 审查清单(评审者逐项过,不适用项标 N/A)

- [x] **判别剃刀**:新增 EdgeBarMetricsTests 断言字面值,mutate.sh 证实有牙
- [x] **证据纪律**:CPU 两批 bench 原始数据已入手册(第一批仅自述，已披露);边栏改动无真机证据(P3,已交由协调者告知用户)
- [x] **Swift 6 并发**:N/A——纯 SwiftUI 视图,无新隔离/回调
- [x] **最小改动**:每行对应三条需求(5 分钟 / 变色环 / 右侧左对齐)
- [x] **错误路径**:N/A——无可失败路径
- [x] **坑总目录对照**:CA 环按 Edge Bar 坑 3 的 CABasicAnimation + 子层 + hitTest→nil 范式;无 repeatForever/opacity 隐藏;边栏 label 仍在 body clipShape 内
- [x] **教训候选**:见 Findings 尾部
- [x] **文档同步**:AGENTS.md / README / README_CN / 截图均已更新

## 评审方法提示(给评审会话)

在 worktree 里:`git diff 741959ac1271001a6fc3bea2d20da50cdb6dd4b9...HEAD` 看全量改动;重要文件直接读上下文,
别只看 diff 片段。发现问题先列 Findings(标 CHANGES_NEEDED),修完复审再改
APPROVED。APPROVED 意味着:"我愿意为这个合并背书"——不是"看起来没毛病"。
