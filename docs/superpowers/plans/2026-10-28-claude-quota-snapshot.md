# Claude 额度快照源(零凭证)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: 按仓库 implement-with-review 工作流逐任务实现(executing-plans 纪律:一任务一验证一提交,checkbox 同任务勾选)。

**Goal:** Claude 额度从「解密凭证调 Anthropic API」改为「读 claude-hud 快照文件」,并删除 NemoNotch 全部 Claude 凭证读取路径(安全团队 EDR 告警归零)。

**Architecture:** claude-hud(用户已装的状态栏渲染器)把 Claude Code 随 statusline stdin 推送的服务端 `rate_limits` 原子写成 `~/.claude/usage-snapshot.json`;`fetchClaude()` 改为读该文件、经纯 parser 映射为现有 `.fiveHour`/`.sevenDay` tiers。凭证缓存、`~/.claude/.credentials.json` 读取、Keychain/security CLI、API 调用全部删除。

**Tech Stack:** Swift 6 + Swift Testing;本地化 String Catalog(经 `scripts/xcstrings.py`)。

**Spec:** 本文档「设计事实」节(2026-10-28 本机端到端实证,无独立 spec 文档)。

## 设计事实(实证锚点)

1. 快照格式(e2e 实测:真实 `~/.claude/plugins/claude-hud/statusline.mjs` + 带 `rate_limits` 的合成 stdin):

   ```json
   {
     "updated_at": "2026-10-28T09:45:53.129Z",
     "five_hour": { "used_percentage": 42, "resets_at": "2026-09-21T14:13:20.000Z" },
     "seven_day": { "used_percentage": 17, "resets_at": "2026-09-28T12:53:20.000Z" }
   }
   ```

   - `updated_at`/`resets_at` 是 ISO8601 字符串,**可能带毫秒**;`used_percentage` 是 0–100 整数(claude-hud 已取整);`resets_at` 可为 null。
   - 写入条件:claude-hud 配置 `display.externalUsageWritePath` 为**绝对 .json 路径**(源码 `path.isAbsolute` 检查,`~` 前缀**静默不生效**);原子写(0600);30s 节流或值变化才写;两个窗口都空时**不写文件**。
2. 删除面(全部 claude 专属,codex/gemini 已确认各有独立 parser):`+Claude.swift` 的 `readClaudeCredential`(明文缓存 → `.credentials.json` → Keychain 三级)、`writeClaudeCache`、`invalidateClaudeCache`;`Models/UsageQuota.swift` 的 `parseClaudeCredentials`;`UsageQuotaService.swift` 常量 `claudeKeychainService / useSecurityCLIForClaudeKeychain / claudeCredentialsURL / claudeCacheURL / claudeUsageURL`;`+Keychain.swift` 的 `.claude` 分支。
3. tiers 形状对齐:API 版解析产 `.fiveHour/.sevenDay` 两窗(`Models/UsageQuota.swift:217-223`),快照同形状 → UI / QuotaAlertMonitor 零改动。
4. 边界安全(已核实):`Models/QuotaAlert.swift:58` 只让 `.valid` 且非空 tiers 参与检测 → 新状态不可能伪造「额度已恢复」卡。
5. 数据新鲜度:快照只在 Claude 会话渲染 statusline 时刷新;无会话时停在最后值(这正是 EDR 期望的行为——没会话就不该有网络轮询)。

## 状态语义(决策)

- `CredentialStatus` 新增两 case:`snapshotMissing`(文件不在 → 提示配置 claude-hud)、`snapshotStale`(超龄 → 等会话刷新,不显示旧百分比)。
- 新鲜阈值 5h(`updated_at` 距 now):五小时窗口滚动后旧值不可信。常量 `claudeSnapshotFreshInterval: TimeInterval = 5 * 3600`,注释写明理由。
- **日志纪律**(AGENTS「轮询循环记状态迁移」):60s 刷新里只在状态**变化**时打 `.info`(服务记 `lastClaudeQuotaLogState`),否则 `.debug`——防「AX not trusted」式刷屏事故重演。

## Global Constraints

- Swift Testing(`import Testing`/`@Test`/`#expect`),不用 XCTest。
- 测试经 worktree 内 `sh scripts/affected-tests.sh` 选类,**禁手挑 --only**;报告引脚本退出码与日志。
- UI 字符串进 `NemoNotch/Resources/Localizable.xcstrings`(en + zh-Hans),经 `python3 scripts/xcstrings.py format` 归一。
- 提交全部在 worktree 内(主检出直提被钩子拦);每任务一提交,commit message 引用任务;plan checkbox 同任务勾选。
- **范围纪律:zcode / Codex / Gemini 配额路径一行不动**(用户拍板 2026-10-28:只改 claude)。

## Review Focus

1. 快照文件不存在 → `.snapshotMissing`,不崩、不误显示 —— Task 1 测试。
2. `updated_at` 超龄(>5h)→ `.snapshotStale` 无 tiers,不出旧百分比 —— Task 1 测试 + 变异验证。
3. `resets_at` 带毫秒 ISO(`…53.129Z`,实测格式)解析失败 → tier 仍在、resetsAt 为 nil(不丢整窗) —— Task 1 测试。
4. 单窗口缺失(只有 five_hour)→ 一个 tier,不失败 —— Task 1 测试。
5. 凭证路径删除残留 → 全仓 grep(`claude-cred|.credentials.json|useSecurityCLI|claudeKeychainService|parseClaudeCredentials|claudeUsageURL`)只剩 codex/gemini 各自合法引用 —— Task 3 步骤。

---

### Task 1: 快照 parser + 新状态(纯逻辑)

**Files:**
- Modify: `NemoNotch/Models/UsageQuota.swift`(`CredentialStatus` 加两 case,doc comment 更新;新增 `ClaudeUsageSnapshotParser` 与常量 `claudeSnapshotFreshInterval`,放在现有 parser 同处)
- Test: `NemoNotchTests/UsageQuotaTests.swift`(新 suite)

**Interfaces:**
- Produces: `enum ClaudeUsageSnapshotParser { static func parse(data: Data?, now: Date) -> ProviderUsageQuota }`,规则:
  - `data == nil` → `.snapshotMissing`
  - JSON 坏 / 非对象 → `.parseError`
  - `updated_at` 缺失或距 now > 5h → `.snapshotStale`,tiers 为空
  - `five_hour`/`seven_day` 至少一个 `used_percentage` 为有限数 → `.valid` + 对应 tier(window 映射 `five_hour→.fiveHour`、`seven_day→.sevenDay`;utilization 转 Double;`resets_at` 解析失败 → nil,不丢窗口)
  - 两个窗口都缺 → `.parseError`
  - `provider: .claude`,`fetchedAt: now`

- [x] **Step 1: 写失败测试**(fixture 用「设计事实」第 1 条的实测 JSON 原文;覆盖 Review Focus 1–4 + happy path 双窗)

- [x] **Step 2: 跑 `sh scripts/affected-tests.sh` 确认新测试红**(parser 未定义)

- [x] **Step 3: 实现 parser**。ISO 解析用两个 `ISO8601DateFormatter`(带 `.withFractionalSeconds` 与不带,先后尝试)

- [x] **Step 4: 跑 `sh scripts/affected-tests.sh` 确认绿**(引退出码)

- [x] **Step 5: 变异验证 staleness 规则有牙**:`sh scripts/mutate.sh NemoNotch/Models/UsageQuota.swift "5 * 3600" "5 * 36000" --only UsageQuotaTests`(阈值放宽 10 倍,超龄测试必须变红;文件由脚本 trap 恢复)

- [x] **Step 6: Commit** — `feat(quota): claude snapshot parser + snapshotMissing/Stale status`

### Task 2: fetchClaude 换轨(读快照)

**Files:**
- Modify: `NemoNotch/Services/UsageQuotaService.swift`(常量 `claudeSnapshotURL` = `~/.claude/usage-snapshot.json`;`lastClaudeQuotaLogState` 记录变量)
- Modify: `NemoNotch/Services/UsageQuotaService+Claude.swift`(重写 `fetchClaude()`;**暂不删**凭证函数——Task 3 删)

**Interfaces:**
- Consumes: Task 1 的 `ClaudeUsageSnapshotParser.parse(data:now:)`。
- Produces: `fetchClaude() async -> ProviderUsageQuota` 签名不变,`refresh()` 零改。实现 = 内联读文件(`try? Data(contentsOf:)`,约 200B,主线程可忽略,注释写明)→ parser → 按状态变化打日志。

- [x] **Step 1: 实现换轨**(fetchClaude 不再引用 token/URLSession;`+Claude.swift` 里 `import Security` 等若仅凭证路径使用可留待 Task 3 一并清)

- [x] **Step 2: 跑 `sh scripts/affected-tests.sh` 守绿**(接线薄层,逻辑已在 Task 1 测过——判别剃刀不满足的凑数测试不写)

- [x] **Step 3: 核验零网络**:`rg -n "URLSession|api.anthropic" NemoNotch/Services/UsageQuotaService+Claude.swift` 零命中

- [x] **Step 4: Commit** — `feat(quota): claude quota reads statusline snapshot`

### Task 3: 删除凭证机器 + 遗留秘密清理

**Files:**
- Modify: `NemoNotch/Services/UsageQuotaService+Claude.swift`(删 `readClaudeCredential`/`writeClaudeCache`/`invalidateClaudeCache`)
- Modify: `NemoNotch/Services/UsageQuotaService.swift`(删 5 个凭证常量;init 加一行:best-effort 删遗留 `~/.NemoNotch/claude-cred.json`,注释 why——我们写的明文 token 副本,凭证路径删除后不能永久留在用户盘上)
- Modify: `NemoNotch/Services/UsageQuotaService+Keychain.swift`(删 `.claude` 分支;codex 保留)
- Modify: `NemoNotch/Models/UsageQuota.swift`(删 `parseClaudeCredentials`)
- Modify: `NemoNotchTests/UsageQuotaTests.swift`(删旧 claude credential 测试)

- [x] **Step 1: 删除上述代码**(编译器引导清干净;`authorize(provider)` 与 `keychainService(for:)` 的 switch 更新)

- [x] **Step 2: 跑 `sh scripts/affected-tests.sh` 守绿**

- [x] **Step 3: 残留 grep(Review Focus 5)**:`rg -n "claude-cred|\.credentials\.json|useSecurityCLI|claudeKeychainService|parseClaudeCredentials|claudeUsageURL" NemoNotch/ NemoNotchTests/` 逐条人工核验为 codex/gemini 合法引用或迁移清理注释

- [x] **Step 4: Commit** — `refactor(quota): remove claude credential access entirely`

### Task 4: UI 状态文案 + 本地化

**Files:**
- Modify: `NemoNotch/Tabs/UsageQuotaCardView.swift:207-213`(`statusKey` switch 加两 case → `quota.status.snapshot_missing` / `quota.status.snapshot_stale`)
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

- [x] **Step 1: statusKey 两新 case;文案**:en `Configure claude-hud usage snapshot` / `Waiting for a Claude session`;zh-Hans `需配置 claude-hud 快照` / `等待 Claude 会话刷新`(经 `python3 scripts/xcstrings.py format` 归一,目录格式零 churn)

- [x] **Step 2: 跑 `python3 scripts/xcstrings.py check` + `sh scripts/affected-tests.sh` 守绿**

- [x] **Step 3: Commit** — `feat(quota): snapshot status copy (en/zh-Hans)`

### Task 5: 文档对账

**Files:**
- Modify: `AGENTS.md`(「Usage quota 的授权陷阱」段:删 claude 凭证/缓存/Keychain 叙事,换成快照源两行——路径、绝对路径要求、5h 新鲜阈值、日志纪律;明确 zcode/Codex/Gemini 保持现状是拍板)
- Modify: `README.md` / `README_CN.md`(grep `凭证|credentials|Keychain` 中 claude quota 相关表述,有则同步)
- 检查: `docs/experience-playbook.md`(引用 claude 凭证现状的段落)

- [x] **Step 1: 全仓 grep 旧口径**(AGENTS.md、docs/、代码注释、测试注释:`claude-cred`、`credentials.json` 的 claude 语境、`security CLI`、`Claude Code-credentials`),逐一改写或确认保留理由

- [x] **Step 2: `sh scripts/doc-audit.sh` 绿**(引退出码)

- [x] **Step 3: Commit** — `docs(quota): claude snapshot source replaces credential path`

## 部署后机器侧步骤(主对话执行,不在 worktree)

1. 写 `~/.claude/claude-hud.json`:`{"display":{"externalUsageWritePath":"/Users/aa00930/.claude/usage-snapshot.json"}}`(**绝对路径**,tilde 静默不生效)。
2. 确认 `~/.NemoNotch/claude-cred.json` 已被迁移清理删除。
3. `git feat-done claude-quota-snapshot`(合并 + post-merge 自动构建部署)。
4. 真机验证:起一个 claude 会话(任意交互一拍让 statusline 渲染)→ NemoNotch AI tab / 边栏 Claude 行显示 5h/7d 百分比;无会话时显示「等待 Claude 会话刷新」。
