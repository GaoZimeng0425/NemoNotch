# 设置内 Agent 接入指南 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 设置 → 提醒与动效的「外部应用 Toast」区块内,提供可折叠展开、一键复制的 agent 接入指南(agent 拿去即可为任意宿主应用生成 toast 接入脚本)。

**Architecture:** 指南全文为 Swift 多行字符串常量(与 `docs/external-toast-agent-guide.md` 同源,注释标注同步纪律),挂在新视图 `ExternalToastGuideSection`(折叠 DisclosureGroup + 常驻复制按钮);接入 AlertsSettingsPage 既有 external_toast Section;新 key 登记 SettingsSearchIndex。

**Tech Stack:** Swift 6 / SwiftUI(macOS Form)/ Swift Testing

**Spec:** `docs/superpowers/specs/2026-11-03-agent-guide-settings-design.md`

## Global Constraints

- worktree 内开发,一任务一验证一提交;lint/测试引脚本真实退出码。
- 指南正文的唯一事实源 = `docs/external-toast-agent-guide.md`(本 feature 随分支提交);常量文件头注释注明「与该文档同源,改契约两处同一提交」。
- 正文**不进 xcstrings**(verbatim 渲染);只新增 3 个 UI key:`settings.external_toast.guide.header` / `.copy` / `.copied`(en + zh-Hans,走 `python3 scripts/xcstrings.py format` 归一)。
- 新 key 必须登记 `SettingsSearchIndex` 的 `.alerts` keys(教训①,漏登记出过 P2)。
- UI 字符串经 `String(localized:)` 或 SwiftUI key 解析的,应用内语言切换要能跟随(仓库既有模式,勿引入新机制)。

## Review Focus

1. **复制的是完整指南而非片段**——Task 1 e2e:`pbpaste` 首行含标题、含 `v1/toast` 与验收清单尾段。
2. **常量与文档同源不漂**——Task 1 锚点单测(常量含 `v1/toast`/`hook-port`/`hook-token`/`X-NemoNotch-Token`/字段表关键词/验收清单标题),变异验证有牙。
3. **搜索能找到**——Task 1 登记后 `rg` 核对 SettingsSearchIndex 含 3 个新 key(en+zh-Hans 值进 xcstrings)。
4. **折叠态不复制展开才可见的内容也能复制**(按钮常驻,折叠时可复制)——Task 1 e2e 折叠态点复制。
5. **应用内切语言后区块标题/按钮跟随切换**(正文不变)——Task 1 实现后手测或依赖既有机制说明。

---

### Task 1: 指南常量 + 视图 + 设置页接入 + 搜索索引

**Files:**
- Create: `NemoNotch/Settings/Pages/ExternalToastGuideSection.swift`
- Modify: `NemoNotch/Settings/Pages/AlertsSettingsPage.swift`(external_toast Section 内追加)
- Modify: `NemoNotch/Settings/SettingsSearchIndex.swift`(`.alerts` keys + 3 个新 key)
- Modify: `NemoNotch/Resources/Localizable.xcstrings`
- Test: `NemoNotchTests/ExternalToastGuideTests.swift`

**Interfaces:**
- Produces:
  - `enum ExternalToastGuide { static let text: String }`(完整指南正文,同源注释)
  - `struct ExternalToastGuideSection: View`(无参;内部 `@State private var copied = false`)
  - xcstrings keys:`settings.external_toast.guide.header` = 「接入指南」/"Agent onboarding guide";`.copy` = 「复制指南」/"Copy guide";`.copied` = 「已复制」/"Copied"

- [ ] **Step 1: 写失败测试** `ExternalToastGuideTests`(Swift Testing):断言 `ExternalToastGuide.text` 非空、含 `"POST http://127.0.0.1:<port>/v1/toast"` 或 `"/v1/toast"`、含 `"hook-port"`、`"hook-token"`、`"X-NemoNotch-Token"`、字段表关键词 `"jumpBundleId"`、验收清单标题 `"验收清单"`
- [ ] **Step 2: 跑红** `sh scripts/test.sh --only ExternalToastGuideTests`(编译失败即红)
- [ ] **Step 3: 实现**:
  - `ExternalToastGuideSection.swift`:常量(从 `docs/external-toast-agent-guide.md` 全文拷入)+ 视图——`DisclosureGroup("settings.external_toast.guide.header")` 内 `ScrollView { Text(verbatim:).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }.frame(maxHeight: 320)`;DisclosureGroup 上方或 label 尾部放 `Button`(复制动作 = `NSPasteboard.general.clearContents()` + `setString(ExternalToastGuide.text, forType: .string)`(先例 `KeepAwakeSettingsView.swift:62`),点击后 `copied = true` + `Task { sleep 2s; copied = false }`,按钮文案按 `copied` 切 `.copy`/`.copied`;**按钮在折叠态也可见可点**(放 DisclosureGroup 的 label 行内或其上方,不放进 content)
  - `AlertsSettingsPage.swift`:external_toast Section 的 hint Text 之后追加 `ExternalToastGuideSection()`
  - `SettingsSearchIndex.swift`:`.alerts` keys 数组追加 `"settings.external_toast.guide.header"`、`".copy"`、`".copied"`
  - xcstrings:3 key 双语(`python3 scripts/xcstrings.py format` 归一)
- [ ] **Step 4: 跑绿** `sh scripts/test.sh --only ExternalToastGuideTests` + `sh scripts/lint.sh --staged --fix`(重新暂存)
- [ ] **Step 5: e2e(部署后)**:`./build.sh` → 设置 → 提醒与动效 → 外部应用 Toast 区块:折叠态点「复制指南」→ 终端 `pbpaste | head -3` 见标题、`pbpaste | grep -c "v1/toast"` ≥ 1;展开见 monospace 正文。记录输出
- [ ] **Step 6: Commit** `feat(guide-ui): agent onboarding guide section with copy (Task 1)`(含 docs/external-toast-agent-guide.md 入库)

### Task 2: README 提及 + 全量验证

**Files:**
- Modify: `README.md` / `README_CN.md`(External Toast API 节尾各一句:「设置 → 提醒与动效 内有一键复制的 agent 接入指南」/ 英文对译)

- [ ] **Step 1: README×2 各加一句**(指向设置内指南;不改契约描述)
- [ ] **Step 2: 全量验证** `sh scripts/affected-tests.sh && sh scripts/lint.sh && sh scripts/doc-audit.sh && sh scripts/check-arch.sh`(引退出码)
- [ ] **Step 3: Commit** `docs(guide-ui): point README to in-app agent guide (Task 2)`
