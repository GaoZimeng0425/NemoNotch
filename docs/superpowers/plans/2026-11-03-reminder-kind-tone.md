# 提醒类型系统(ReminderKind × tone)实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans(本仓恒选,主对话逐任务实现)。Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 把刘海层提醒改为「只有需要用户接手的时刻才弹」,颜色(绿/amber/blue/red)表达接手原因,措辞表达具体事件;捎带修复四处时机错误。

**Architecture:** 两轴正交:既有 `CompletionSource`(谁,定 logo)× 新 `ReminderKind`(事件,定措辞)→ `ReminderTone`(4 色,定环/辉光色)。检测全部纯函数(下降沿 kind 化、消失=中断、上升沿等审批),队列加 sticky 与跨键顶换两个原语,视觉层只把色数组参数化(CA 结构不动)。

**Tech Stack:** Swift 6 / SwiftUI / Core Animation;Swift Testing;无新依赖。

**Spec:** `docs/superpowers/specs/2026-11-03-reminder-kind-tone-design.md`(语义表、五条审计口径、捎带修复清单都以 spec 为准)。

## Global Constraints

- 色值唯一出处 `ReminderTone`,全 app 读它,verbatim:green main `rgb(77,217,115)` light `(180,242,198)` deep `(34,168,84)` hot `(111,245,150)`;amber main `(255,184,46)` light `(255,224,138)` deep `(224,143,0)` hot `(255,159,26)`;blue main `(64,158,255)` light `(166,208,255)` deep `(31,111,209)` hot `(43,140,255)`;red main `(255,95,87)` light `(255,179,173)` deep `(217,48,39)` hot `(255,122,114)`。
- 只测纯逻辑(parser/检测器/队列/映射);UI 层不建测试,靠构建 + `--uitest` 截图。
- 动画纪律:环/辉光只换颜色数组与色对,conic 渐变、4s 旋转、双脉冲、mask 全部原样;禁 TimelineView/repeatForever。
- xcstrings 只经 `scripts/xcstrings.py` 归一;en + zh-Hans。
- 整个 feature 在 `git feat reminder-kind-tone` worktree 内完成;**isActive 误报修复与新卡接线必须同一 feature 分支,禁止中途 feat-done**(否则出现"提问无任何提示"的空窗)。执行者=主对话。
- AGENTS.md「完成闪光 / Toast」节、README.md、README_CN.md 与代码同一提交改(文档对账门禁)。

## Review Focus

1. **提问弹完成卡的空窗**——isActive 修复与 attention 卡若分两次发布,中间 AskUserQuestion 完全无提示。→ T3 回归测试(processing→waiting 不报完成)+ 全程单分支纪律。
2. **attention 卡挂死**——opencode 审批桥 600s > 旧卡寿命,若撤回链路断,卡会挂满上限。→ T3 retracted 测试、T4 sticky 测试、T7 observe 接线。
3. **跨键替换删错卡**——fail 卡只许顶掉**同会话**的 ai 卡,不能碰别的会话或日历/通知卡。→ T4 demote 测试三断言。
4. **红档误报放大**——长构建/子代理静默 5 分钟,若 isPreToolUse 豁免缺失,会弹红色"会话中断"(比绿色假完成更吓人)。→ T5 `StaleDemotion` 测试。
5. **开关组合下的辉光**——`failureToastEnabled=off` 时红不参与仲裁,amber 次高照闪,不得整窗无辉光。→ T1 `pick` 测试(先过滤被关 tone 再取最高)+ T7 分流。

---

### Task 1: ReminderKind / ReminderTone 模型

**Files:**
- Create: `NemoNotch/Models/ReminderKind.swift`
- Test: `NemoNotchTests/ReminderKindTests.swift`

**Interfaces (Produces):**
- `enum ReminderKind: Equatable { case turnDone, needsDecision, needsPlanApproval, needsApproval, agentError, apiError, sessionLost }`
- `enum ReminderTone: CaseIterable, Equatable { case green, amber, blue, red }`
- `ReminderKind.tone: ReminderTone`(turnDone→green;needsDecision/needsPlanApproval→amber;needsApproval→blue;agentError/apiError/sessionLost→red)
- `ReminderKind.attentionKind(forToolName: String?) -> ReminderKind?`:规范化(小写+去下划线)后 `askuserquestion`/`askuser`→needsDecision,`exitplanmode`→needsPlanApproval,**其余(含 nil/未知工具)→needsApproval**。命名与 `PermissionContext.isInteractiveTool`(SessionPhase.swift:195)同一套规范化。
- `ReminderTone`: `main: Color`、`hot: Color`、`ring: [NSColor]`([main, light, deep, main],conic 起止同色)、`flashPriority: Int`(red>amber>blue>green)
- `ReminderTone.pick(_ tones: [ReminderTone]) -> ReminderTone?`(空→nil,取优先级最高)

- [x] **Step 1: 失败测试** — tone 映射 7 kind 全断言;`attentionKind(forToolName:)` 断言 `"AskUserQuestion"/"ask_user_question"/"AskUser"/"ExitPlanMode"/"Bash"/nil` 六个输入;`pick([.green,.red])==.red`、`pick([])==nil`;每 tone `ring.count==4` 且首尾相等。
- [x] **Step 2: 跑测确认红** — Run: `sh scripts/test.sh --only ReminderKindTests` · Expected: FAIL(类型不存在,编译错)。
- [x] **Step 3: 实现** — 纯枚举+switch,色值抄 Global Constraints 的 RGB 字面量。
- [x] **Step 4: 跑测确认绿** — 同命令 · PASS。
- [x] **Step 5: Commit** — `git add … && git commit -m "feat(reminder): ReminderKind×tone 模型与色表"`

### Task 2: 状态机补 compacting 出边

**Files:**
- Modify: `NemoNotch/Models/SessionPhase.swift:85-87`(canTransition)
- Test: `NemoNotchTests/SessionPhaseTests.swift`(不存在则新建,存在则追加)

**Interfaces (Produces):** `canTransition` 接受 `(.compacting, .waitingForInput) / (.compacting, .waitingForApproval) / (.compacting, .idle)`。

- [x] **Step 1: 失败测试** — 三条新边 `canTransition == true` 各一断言(现状 false,先红)。
- [x] **Step 2: 跑测确认红** — `sh scripts/test.sh --only SessionPhaseTests`。
- [x] **Step 3: 实现** — 在 `(.compacting, .processing), (.compacting, .ended)` 分支补三个 case,一行注释引用 spec「compacting 死胡同」。
- [x] **Step 4: 跑测确认绿 + Commit** — `fix(phase): compacting 可转 waiting/idle,堵死 30min 空转死胡同`

### Task 3: 检测器 kind 化 + 消失=中断 + AttentionDetector

**Files:**
- Modify: `NemoNotch/Services/CompletionDetector.swift`(CompletionItem/CompletionCandidate 扩展、CompletionDetector、新增 AttentionDetector)
- Test: `NemoNotchTests/CompletionDetectorTests.swift`(追加)

**Interfaces (Produces):**
- `CompletionItem` 增:`var kind: ReminderKind? = nil`、`var sticky = false`、`var sessionKey: String?`(computed:`key` 以 `ai:`/`ask:`/`fail:` 开头取后段,其余 nil)
- `CompletionCandidate` 增:`var attentionKind: ReminderKind? = nil`、`var completesAs: ReminderKind = .turnDone`、`var wasError = false`
- `CompletionDetector.step`:完成项 `item.kind = candidate.completesAs`;**prior 活跃而后快照消失的单元 → 报 `kind == .sessionLost` 的 CompletionItem**(骨架字段取 prior 快照),其余消失仍丢弃(先例:先 inactive 再消失不报)——detector 内部 prior 从 `[String: Bool]` 改存小型快照(active/error/骨架)。
- `struct AttentionDetector`:`mutating func step(_ entries: [AttentionEntry]) -> (arrived: [(key: String, kind: ReminderKind)], retracted: [String])`,`typealias AttentionEntry = (key: String, attention: ReminderKind?)`。幂等:同 key 已在等待中不重发(kind 变了也不重发,对齐 `RingKind` 的 arrival-gesture 哲学,注释引用 EdgeBarRing.swift:110);`attention → nil` 发 retracted。

- [x] **Step 1: 失败测试**(全部先红):
  - 回归:candidate active(processing)→ 下一拍 `attentionKind = .needsDecision`:**不报完成**(现状会报,这就是误报守卫)。
  - active→inactive 且 completesAs=.turnDone → 报完成且 `kind == .turnDone`;completesAs=.sessionLost → `kind == .sessionLost`。
  - prior active、本拍 key 消失 → 报 sessionLost,字段取 prior 骨架;prior inactive 消失 → 不报。
  - agent:wasError=true → inactive → `kind == .agentError`;wasError=false → `.turnDone`。
  - AttentionDetector:nil→needsApproval 报 arrived;再次 step 同 kind 不重发;needsDecision→nil 报 retracted。
  - `sessionKey`:`"ai:abc"`→`abc`、`"ask:abc"`→`abc`、`"fail:abc"`→`abc`、`"agent:x"`/`nil`→nil。
- [x] **Step 2: 跑测确认红** — `sh scripts/test.sh --only CompletionDetectorTests`。
- [x] **Step 3: 实现** — 按 Interfaces;AttentionDetector 是独立 struct,与 CompletionDetector 同文件同域。
- [x] **Step 4: 跑测确认绿 + Commit** — `feat(reminder): 完成边沿 kind 化,消失=sessionLost,新增 AttentionDetector`
- [x] **Step 5: 变异验牙** — `sh scripts/mutate.sh NemoNotch/Services/CompletionDetector.swift "if prior[candidate.key] == true, !candidate.isActive {" "if false && prior[candidate.key] == true, !candidate.isActive {" --only CompletionDetectorTests` · Expected: exit 0(变红)。

### Task 4: 队列 sticky 与跨键顶换

**Files:**
- Modify: `NemoNotch/Services/CompletionToastQueue.swift`
- Test: `NemoNotchTests/CompletionToastQueueTests.swift`(追加)

**Interfaces (Produces):**
- sticky 语义:`expire(now:)` 跳过 `item.sticky` 的卡;`nextDeadline` 不为 sticky 卡排期;等待堆递补保持 sticky;同 key 顶换时新 item 的 sticky 生效(attention 卡重推仍 sticky)。
- `mutating func demote(sessionKey: String, keeping toastKey: String) -> [CompletionToast]`:从显示行与等待堆移除所有 `item.sessionKey == sessionKey && item.toastKey != keeping` 的卡,返回被移除者;无匹配返回 `[]`。

- [x] **Step 1: 失败测试** — sticky 卡过期点后 `expire` 不收它、邻卡照常收;`nextDeadline` 只算非 sticky;`demote("abc", keeping: "fail:abc")` 移除 `ai:abc`、保留 `fail:abc` 与 `ai:other` 与日历卡(`name:` 键,sessionKey nil);返回值=被移除卡。
- [x] **Step 2: 跑测确认红 → Step 3: 实现 → Step 4: 绿** — `sh scripts/test.sh --only CompletionToastQueueTests`。
- [x] **Step 5: Commit** — `feat(reminder): 队列 sticky 卡与按会话跨键顶换`

### Task 5: 四家降级豁免统一(StaleDemotion 纯函数)

**Files:**
- Modify: `NemoNotch/Models/SessionPhase.swift`(文件尾追加 `enum StaleDemotion`);`Services/ClaudeCodeService.swift:554-581`、`Services/GeminiProvider.swift`、`Services/OpencodeProvider.swift`、`Services/ZcodeProvider.swift:192-222`(各 demote 循环)
- Test: `NemoNotchTests/SessionPhaseTests.swift`(追加);回归护栏 = 既有 `ZcodeProviderTests`

**Interfaces (Produces):**
- `enum StaleDemotion { static func shouldDemote(phase: SessionPhase, isPreToolUse: Bool, recordStatusKnown: Bool = false) -> Bool }`:.idle/.ended→false;**isWaitingForApproval→false**(审批桥自带超时会挪 phase);isPreToolUse→false;recordStatusKnown→false(Claude 专属参数);其余 true。
- 四家 demote 循环体改调它(zcode 把现有内联三条件替换为调用,行为不变)。

- [x] **Step 1: 失败测试** — shouldDemote 六断言(上述各分支 + processing+全 false→true)。
- [x] **Step 2: 红 → Step 3: 实现函数 + 四家循环替换** — Claude 调用处传 `recordStatusKnown:`;Gemini/opencode/zcode 用默认。
- [x] **Step 4: 绿(含 ZcodeProviderTests 既有全绿)+ Commit** — `fix(reminder): 降级统一豁免开着的工具与等待审批,三家补 isPreToolUse`

### Task 6: apiError 信号校准与检测(Claude)

**Files:**
- Create: `NemoNotch/Models/ApiErrorMarker.swift`
- Modify: `NemoNotch/Models/AIProvider.swift`(AISessionState 增 `var hitApiError = false`;`beginTurn()`(:278)重置它);`NemoNotch/Services/ClaudeCodeService.swift:469`(parseConversation 增量解析处)
- Test: `NemoNotchTests/ApiErrorMarkerTests.swift`

**Interfaces (Produces):**
- `enum ApiErrorMarker { static func isApiError(_ entry: [String: Any]) -> Bool }` — 输入一条 transcript JSON 条目。
- parseConversation:增量段命中 → `store.mutate { $0.hitApiError = true }`。

- [x] **Step 1: 真样本校准(证据纪律:先拿样本再定模式)** — Run: `grep -rl "isApiErrorMessage\|API Error" ~/.claude/projects --include="*.jsonl" | head -3`,对命中文件 `grep -h -m 3 "isApiErrorMessage\|API Error" <file>`;把命中的确切字段/文本形状抄进测试字面量与函数注释。候选信号(以样本为准,不凭记忆):`isApiErrorMessage == true`;text 以 `"API Error"` 开头;含 `"rate limit"`/`"You've hit"`/`"overloaded"`(大小写不敏感)。
- [x] **Step 2: 失败测试** — 用样本字面量断言 `isApiError == true`;普通 assistant 消息/工具结果 == false。
- [x] **Step 3: 红 → 实现 → 绿** — 匹配逻辑纯函数;parseConversation 每增量条目过一遍(与 UserPrompt 过滤同位置)。
- [x] **Step 4: Commit** — `feat(reminder): transcript API 错误标记(hitApiError),样本校准`

### Task 7: CompletionFlashService 全接线

**Files:**
- Modify: `NemoNotch/Services/CompletionFlashService.swift`
- Test: 纯逻辑已由 T1/T3/T4/T5 覆盖;本任务验证 = 全量编译 + 既有测试不红。

**Interfaces (Consumes):** T1 全部;T3 AttentionDetector/CompletionDetector 新参;T4 sticky/demote;T6 hitApiError。
**Interfaces (Produces):** `private(set) var glowTone: ReminderTone = .green`(CompletionFlashView 读它);`private(set) var toasts` 不变形状。

- [x] **Step 1: 快照改造** — `currentCandidates()`:AI 候选 `isActive = session.phase.isActive`(**误报修复落点**,替换 `session.status == .working`,注释引用 spec 审计口径)、`attentionKind = session.attentionKind`(新增 computed:phase 为 waitingForApproval 时按 ctx.toolName 走 `ReminderKind.attentionKind(forToolName:)`,加在 AIProvider.swift)、`completesAs = (phase == .waitingForInput ? .turnDone : .sessionLost)`、item 带 kind/jump 快照;agent 候选 `wasError = (state == .error)`。
- [x] **Step 2: 发射分流(开关只 gate 发射,不过滤快照——否则开关一开旧边沿重放)** — `handle(items:)` 前按 `item.kind?.tone` 分流:green→`completionFlashEnabled`;amber/blue→`attentionToastEnabled`;red→`failureToastEnabled`;off 丢卡。同批辉光:`ReminderTone.pick(被关 tone 过滤后的本批 tones)` → `glowTone`,节流窗内后续只出卡不重闪(现状 inCooldown 分支不变)。
- [x] **Step 3: attention 卡接线** — 服务持 `AttentionDetector`;arrived → `CompletionItem(key: "ask:<id>", kind:, sticky: true, subtitle: InteractivePrompt.summary 或 PermissionContext.displayInput, jump: 快照)` 经 `addToasts`;retracted → `toastQueue.replace(key: "ask:<id>", with: nil, now:)` + `syncToasts()`。
- [x] **Step 4: apiError 迟到红卡** — observe 追加 `store.sortedSessions.map { ($0.id, $0.hitApiError) }`;false→true 时:出 `fail:<id>` 卡(kind `.apiError`,sticky=false),并 `toastQueue.demote(sessionKey: id, keeping: "fail:<id>")` 后 `syncToasts()`;同会话绿卡不在行上(Stop 前就翻了)则只出红卡。
- [x] **Step 5: 跑全量测试 + 抽变异** — `sh scripts/test.sh`(全量)· 绿;`sh scripts/mutate.sh NemoNotch/Services/CompletionFlashService.swift "isActive: session.phase.isActive" "isActive: session.status == .working" --only CompletionDetectorTests` 红即守卫有牙。
- [x] **Step 6: Commit** — `feat(reminder): 服务接线——tone 分流/attention 卡/迟到红卡/误报修复同批落地`

### Task 8: 视觉与措辞

**Files:**
- Modify: `NemoNotch/Notch/CompletionToastView.swift`(RingView 参数化 :319-331、detail 行前缀)、`NemoNotch/Notch/CompletionFlashView.swift:33-64`、`NemoNotch/Resources/Localizable.xcstrings`

**Interfaces (Consumes):** `ReminderTone.ring/main/hot`、`CompletionItem.kind`。

- [x] **Step 1: 环参数化** — `CompletionToastRingView` 的 `static colors` 改 `static let rainbow`(原六色数组)与 `init(cornerRadius:colors: [NSColor])`;`CompletionToastRing` 增参传 `item.kind?.tone.ring ?? .rainbow`;动画/mask/Reduce Motion 原样。
- [x] **Step 2: 辉光换色** — `CompletionFlashView` 用 `service.glowTone.main/.hot` 替换 `NotchTheme.accent/accentHot` 两处;白芯与三层结构、双脉冲不动(**同窗换色即可,不重建窗口**——只改属性不涉可见性翻转,无具文窗口坑)。
- [x] **Step 3: 措辞** — `completionText` 的 detail 行加 kind 前缀(localized key `reminder.kind.turnDone/needsDecision/needsPlanApproval/needsApproval/agentError/apiError/sessionLost`,值照 spec 语义表;`kind == nil` 无前缀);xcstrings 用 `python3 scripts/xcstrings.py format` 归一。
- [x] **Step 4: 截图验证面** — `holdForUITest` 扩展为四种 tone 各一张卡(绿/amber/blue/red),供 `--uitest --flash` 截图核对。
- [x] **Step 5: 编译 + 全量测试 + lint** — `sh scripts/affected-tests.sh` 绿、`sh scripts/lint.sh` 绿。
- [x] **Step 6: Commit** — `feat(reminder): 环/辉光按 tone 分色,卡面措辞分 kind`

### Task 9: 设置开关

**Files:**
- Modify: `NemoNotch/Models/AppSettings.swift`(仿 `notificationToastEnabled` :100 形状)、`NemoNotch/Settings/Pages/AlertsSettingsPage.swift`、`Localizable.xcstrings`
- Test: `NemoNotchTests/AppSettingsReminderToneTests.swift`

**Interfaces (Produces):** `attentionToastEnabled: Bool`(默认 **true**)、`failureToastEnabled: Bool`(默认 **true**);设置页三段:完成提醒(原 `completionFlashEnabled`,文案改 green 专属)/ 需要你决定 / 出错了。

- [x] **Step 1: 失败测试** — 两键默认 true、写入 UserDefaults 后读回(仿 AppSettingsExternalToastTests)。
- [x] **Step 2-4: 红 → 实现(设置页两条 Toggle + hint)→ 绿**。
- [x] **Step 5: Commit** — `feat(reminder): attention/failure 独立开关,完成开关降格 green 专属`

### Task 10: 文档同步与收尾

**Files:**
- Modify: `AGENTS.md`(完成闪光节:用户原则、4 tone 语义、开关矩阵、attention 卡 retract/sticky、消失=sessionLost 规则)、`README.md`、`README_CN.md`

- [x] **Step 1: 文档三处同提交改**(doc-audit 会核对手册引用的脚本路径)。
- [ ] **Step 2: 门禁全套** — `sh scripts/lint.sh` / `sh scripts/doc-audit.sh` / `sh scripts/check-arch.sh` / `sh scripts/plan-audit.sh`(本文件勾框全勾)/ `sh scripts/test.sh` 全量,全绿并引用退出码汇报。
- [ ] **Step 3: 真机验证四条**(spec 验证节):①AskUserQuestion→amber 卡+辉光、答完即撤;②Bash 审批→blue;③正常完成→green;④kill 跑着的 CLI→red「会话中断」。截图留证。
- [ ] **Step 4: 评审 + 合并** — `sh scripts/review.sh reminder-kind-tone` 生成模板,派独立评审子代理(prompt 用 `--prompt` 输出,不带实现思路);APPROVED 后主检出 `git feat-done reminder-kind-tone`(合并即部署+自动 push)。
