# 设计:按接手原因分色的提醒系统(ReminderKind × tone)

日期:2026-11-03 · 状态:待用户批准 · 前置调查:本对话(2026-11-02 起的 hook 状态梳理与配色 mockup)

## 意图与为什么

**改之前用户看到**:刘海下的提醒卡全是同一副脸——彩虹边框、橙色全屏辉光、"完成"措辞。Claude 问一个 AskUserQuestion,刘海先闪一次绿色"完成"辉光(两天日志 24 次实锤,梯级 4);5h 额度打满会话中途死掉,用户收到的也是一张绿色"完成"卡;CLI 进程没了活没干完,要么 5 分钟后假"完成"、要么静默消失。用户分不清"做完了"和"卡在你这儿"。

**改之后用户看到**:需要接手的时刻弹卡 + 辉光,**颜色一眼告诉你要做什么**:绿=回来看结果、amber=来做个决定、blue=来点允许、red=来救火;卡面措辞说明具体发生了什么。

**用户原则(2026-11-03 拍板,本设计的最高约束)**:

> 只有需要我接手的情况才提醒我;我要通过不同颜色知道大致是什么情况需要我接手。turnStarted / toolRunningLong 这种进行中的信息不需要我知道。

推论:完成(turnDone)算接手——轮到你说话了;一切"进行中/知道了就行"的信息类**全部不提醒**(含 contextNearLimit,虽曾列为 v2 候选,按此原则砍掉,80% 红条留在 AI tab 不弹)。

## 目标 / 非目标 / 反目标

**目标**
- v1 交付 4 色 tone × 7 种 kind(语义表见下),覆盖四家 CLI(Claude/Gemini/opencode/zcode)与多 agent(OpenClaw/Hermes)。
- 三处视觉同一语义:toast 卡环、全屏辉光、卡面措辞;色值对齐边栏既有 palette。
- 同一 feature 捎带修复四个已实锤的"时机错误"(见「捎带修复」),不留空窗。

**非目标**
- 信息类提醒(开工/长工具/子代理/压缩/上下文水位)——按用户原则砍。
- 通知镜像卡、外部 POST 卡、日历卡、边栏用量阈值卡、等待提醒系统通知、锁屏面板——通道与开关全部不动(用量阈值卡可后续并入本 enum,本次不做)。
- WaitingReminder(waitedTooLong)保持现状:它是 amber/blue 的超时升级标记,走系统通知通道,默认关。

**反目标**
- 颜色超过 4 档;每 kind 一色(余光分不清第 5 种色)。
- 给非 agent 卡(日历/通知/外部)也上 tone——它们没有"接手"语义,保留彩虹环。

## 核心原则(以后加提醒种类的判据)

- **颜色编码"你该怎么反应",不编码"发生了什么事件"**:green=回来看 / amber=来决定 / blue=来点允许 / red=来救火。
- **枚举(kind)编码"具体发生了什么"**,决定措辞与图标。加新 kind 只问一句"用户该怎么反应",映射到既有 tone,不发明新颜色。
- **两轴正交**:轴 1 `CompletionSource`(谁,已有,定 logo)× 轴 2 `ReminderKind`(本设计新增)。不往 `CompletionSource` 里塞周期节点。

## 语义表(v1 全量)

| kind | tone | 触发边沿 | 卡面措辞前缀(zh / en) | 撤回 |
|---|---|---|---|---|
| `turnDone` | green | 工作态下降沿(Stop / AfterAgent;含聊天气泡回合) | 完成了 / Done | 否,5 分钟到期(现状) |
| `needsDecision` | amber | 进 waitingForApproval 且 `isInteractiveTool`(AskUserQuestion) | 等你选 / Your call | **是**:phase 离开 waitingForApproval 即撤 |
| `needsPlanApproval` | amber | 进 waitingForApproval 且 tool_name == ExitPlanMode | 等你批方案 / Review plan | 同上 |
| `needsApproval` | blue | 进 waitingForApproval 其余(Bash/Edit 权限等) | 等你批 / Approve? | 同上 |
| `agentError` | red | agent(OpenClaw/Hermes)`.error` 终态离开边沿 | 出错了 / Failed | 否 |
| `apiError` | red | transcript 检出额度打满/429/overloaded 且会话因此 Stop(信号清单实现时校准,见「留给实现」) | 出错了(额度/接口) / Hit a limit | 否 |
| `sessionLost` | red | 降级/回收边沿且**从未 Stop**:Claude record 进程消失;zcode 30min 回收;gemini/opencode 5min 静默降级(四家全覆盖,见审计口径 1) | 会话中断 / Session lost | 否 |

- `waitedTooLong` 不是 kind:amber/blue 三种的超时升级标记,维持 WaitingReminder 系统通知通道不变。
- attention 卡身份键 `ask:<会话>`(与完成卡 `ai:<会话>` 独立,答完撤卡、Stop 后的完成卡另行到达);failure 卡 `fail:<会话>` 终态不撤。
- 非 agent 源(日历/通知镜像/外部)不经 kind 轴,环色维持现状彩虹。

## 方案取舍(考虑过的三条路)

1. **每 kind 一色** — 弃:7 种色超出余光分辨力,颜色一多等于没有颜色。
2. **两层 enum(kind → tone,本设计)** — 选:措辞无限细分,颜色锁死 4 档;加 kind 零颜色成本。
3. **只做 tone 不做 kind(换色不换词)** — 弃:额度打满和正常完成同绿同词,最误导的一类继续误导。

## 已拍板的决定

1. **配色 = mockup 方案 B**(用户在 mockup 点选,2026-11-03 文字确认"一起做"同语境):green `rgb(0.30,0.85,0.45)`(= `EdgeBarPalette.green`)、amber `rgb(1.0,0.72,0.18)`(= `EdgeBarPalette.amber`,边栏"等审批"现有色)、blue `rgb(0.25,0.62,1.0)`(现有彩虹环蓝)、red `rgb(1.0,0.37,0.36)`(系统红附近,实现时定)。色值单一出处:`ReminderTone` 的纯映射,环/辉光/将来任何面都读它。
2. **环**:`CompletionToastRingView.colors` 由 `static` 改 init 参数(kind → `[NSColor]` 三色组:light / 主 / deep);conic 渐变、4s 旋转、Reduce Motion 停转、mask 描边全部原样——CA 结构零改动,渲染成本不变。
3. **辉光**:`CompletionFlashView` 的 `NotchTheme.accent`/`accentHot` 换成 tone 主色/hot 色,白芯不动,双脉冲曲线不动。**节流窗内仲裁**:2s 节流窗里多个 tone 同时到,辉光只闪一次、闪优先级最高的:red > amber > blue > green(救火先于一切);toast 卡各出各的,不受仲裁影响。
4. **检测器(全部纯函数,可单测)**:
   - 下降沿(现状 `CompletionDetector`)只负责 `turnDone`,且 `isActive` 改 `session.phase.isActive`(`SessionPhase.swift:18` 已有正确谓词)——这是误报修复,与新卡**同一提交**。
   - 新 `AttentionDetector`:快照 diff 报"进 waitingForApproval"上升沿,按 ctx 分三种 kind;幂等粒度对齐边栏 `RingKind` 的哲学("context changing must not replay the arrival gesture",`EdgeBarRing.swift:110` 注释)——审批上下文变化不重发;phase 离开即发撤回。
   - `agentError`:agent `.error` 离开边沿(现状会当"完成"弹绿,改弹红)。
   - `apiError` / `sessionLost`:见语义表;感知面是 transcript 解析与 Claude record,本 feature 唯一的新增检测工作。
5. **开关**:绿 = 现有 `completionFlashEnabled`;amber+blue = 新 `attentionToastEnabled`(默认开,保住用户现有行为);red = 新 `failureToastEnabled`(默认开)。设置页「提醒与动效」各一条。
6. **本地化**:措辞前缀进 `Localizable.xcstrings`(en + zh-Hans),编辑走 `scripts/xcstrings.py`。

## 捎带修复(与色系同一 feature,同一评审)

1. **审批误报完成**(isActive 改法,上述第 4 条,必须同提交否则留空窗)。
2. **compacting 死胡同**:`SessionPhase.canTransition`(:85)补 `compacting → waitingForInput / waitingForApproval / idle`(现状只允许 →processing/→ended,opencode PreCompact 后直接 Stop 会被拒,徽章空转 30min、每 60s 一条 warn)。
3. **降级循环跳过 `isWaitingForApproval`**:审批桥自带超时(Claude 120s / opencode 600s)会挪 phase,降级别去碰,否则 opencode 等审批跨 5 分钟会新出假"完成"。
4. **Gemini/opencode/Claude 降级补 `isPreToolUse` 豁免**(zcode 已有,`ZcodeProvider.swift:214`):长工具/subagent 静默期不再被 5 分钟降级弹成假完成。

## 验证方式

- 单测(纯逻辑):kind→tone 映射;AttentionDetector 上升沿/幂等/撤回;仲裁优先级;`canTransition` 新增三条边;降级豁免路径;文案 key 存在性。改守卫后 `sh scripts/mutate.sh` 验牙。
- 门禁:`sh scripts/test.sh` 全量、`lint.sh`、`doc-audit.sh`、`check-arch.sh`。
- 真机验证指引:①Claude 里触发一次 AskUserQuestion——amber 环卡 + amber 辉光,答完卡即撤,边栏审批卡照常;②触发一次 Bash 审批——blue;③一轮正常完成——green;④`kill` 一个跑着的 CLI 会话——red sessionLost 卡(不再是假完成)。
- 文档同步义务(同一 feature 提交):AGENTS.md「完成闪光 / Toast」节加 tone 语义与原则;README/README_CN 功能描述。

## 独立审计后定下的口径(2026-11-03,作者裁量;批准时可整体否决)

1. **red 的 provider 覆盖 = 四家全覆盖,不加新感知面。**sessionLost 的证据就是"降级/回收边沿且从未 Stop":Claude record 把 active 会话标为进程消失;zcode 30min 回收;**gemini/opencode 的 5 分钟静默降级边沿同样按 sessionLost 记红**(配合本 feature 的 isPreToolUse 豁免,降级只在"无开着的工具 + 无 Stop + 静默 5 分钟"时发生,死会话的嫌疑远大于完成)。改法是把既有降级边沿的归类从 turnDone 改成 sessionLost,零新检测器。
2. **开关矩阵:三个开关各自独立门禁"该色的卡 + 该色的辉光"。**`completionFlashEnabled` 降格为 green 专属(设置页文案改"完成提醒"),不再是总闸;amber/blue 看 `attentionToastEnabled`、red 看 `failureToastEnabled`,互不越权。已关掉完成闪光的存量用户会开始收到 amber/blue——判断依据:他们关掉的是当时那个误报不断的"完成"闪光,而提问提醒正是修好的部分。
3. **绿→红竞态:绿卡即时出,红卡到达后跨键顶掉同会话的绿卡。**Stop 同步写 phase、transcript 证据晚到(实测链路:phase 在前、解析在后),压制绿卡只能靠延迟;不延迟——t0 时刻绿卡是当时最优知识,红卡(额度/中断)检出后撤掉同会话刚出的 `ai:` 卡、换 `fail:` 卡。给队列加一个"按会话跨键替换"原语,验收句"不再是假完成"在秒级内成立。
4. **attention 卡不计时,挂到撤回;failure 卡照常 5 分钟。**撤回条件 = phase 离开 waitingForApproval(答了 / 桥超时代答 / 终端答了),opencode 600s 桥超时是硬上界——卡最多挂 10 分钟,不会永久占位;仍占 4 张上限,同会话同 kind 顶旧卡,极端多会话同时等审批时挤下的卡照常递补。red 是终态历史事实,5 分钟到期。
5. **辉光仲裁只管"同批",不追认窗口中途。**同一次 handle() 的多个 tone 闪优先级最高者;节流窗中途到达的更高优先级 tone 不重闪、不换色,只出卡(节流窗语义与现状一致,triggerFlash 任务模型零改动)。被关掉的 tone 不参与排序也不触发辉光,次高者闪。"救火红被辉光吞"的补偿 = 红卡本体挂在刘海下,消息不丢。
6. **非 agent 批次的辉光随 green(评审后补拍板,2026-11-03)。**日历/蓝牙等事件类批次(kind==nil)经 handle 走全屏辉光:旧 accent 橙弃用,统一 green——到点=该行动了,归「回来看」档;橙色在四色语义里无意义,保留它等于引入第五色。卡面环仍彩虹(反目标不变)。

## 留给实现的(plan 阶段细化,spec 不锁死)

- **apiError 的 transcript 信号清单**:候选有 `isApiErrorMessage` 标志、"API Error" 文本、429/overloaded/limit 关键词——实现第一步先拿本机真实样本校准(grep `~/.claude/projects` 的 JSONL),不凭记忆定。
- 环三色组(light/deep)与 red 的具体值:mockup 起步,真机微调。
- Glow 窗口在 tone 间切换时是否需要重建(同窗换色 vs 重建)——实现时按「具文窗口」坑条目判断(改可见性才重建,换色不需要)。
- failure 卡与同会话后续完成卡的并存展示(红卡 5 分钟内 Stop 到达出绿卡,两卡同显)——按栈式规则自然处理,不特殊合并。
