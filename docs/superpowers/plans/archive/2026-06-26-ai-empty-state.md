# AI Tab Empty-State Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the AI tab's two bare empty presentations (`idleState`, `recoveryCards`) with one adaptive, polished `emptyConsole` that shows all three monitored CLIs + their readiness, a breathing hero, and a run hint.

**Architecture:** Pure SwiftUI refactor inside `NemoNotch/Tabs/AIChatTab.swift`. The `body` empty-branch collapses to a single `emptyConsole` view that adapts on the existing `hasAnyReadyProvider`; a `providerStatusRow` helper renders each provider's Ready-pill / Install / Enable control. Six new localized strings.

**Tech Stack:** Swift 6 + SwiftUI, `Localizable.xcstrings` string catalog, existing `NotchTheme` tokens and `notchCard` modifier.

## Global Constraints

- Swift 6, macOS. Match existing `AIChatTab` style and `NotchTheme` tokens (`accent`, `accentHot`, `surface`, `textPrimary/Secondary/Tertiary`).
- Empty state caps inner content at `maxWidth: 360`, centered.
- Show all three providers (Claude Code, Gemini CLI, opencode) always; trailing control is Ready-pill / Install / Enable by `ProviderCardKind` (`.ready/.install/.reenable`).
- Run hint shown only when `hasAnyReadyProvider`. Server-status dot (`serverStatus`) always shown.
- Hero glyph breathes (opacity 1.0↔0.55, ease-in-out 1.6s, autoreversing, forever).
- New strings added to `NemoNotch/Resources/Localizable.xcstrings` (en + zh-Hans), preserving Xcode's `" : "` format and minimal diff.
- Do NOT edit `project.pbxproj`. No unit tests (pure view code — project convention); verify via clean build + manual.
- Build: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" 2>&1 | tail -8` → `** BUILD SUCCEEDED **`. xcodebuild takes minutes; be patient.

## File Structure

- Modify: `NemoNotch/Resources/Localizable.xcstrings` — add 6 keys.
- Modify: `NemoNotch/Tabs/AIChatTab.swift` — add `emptyConsole`/`emptyHero`/`providerStatusList`/`providerStatusRow`/`emptyFooter` + `heroBreathe` state; simplify `body`; remove `idleState`, `recoveryCards`, `providerCard`, `hasRecoveryCards`.

---

## Task 1: Add localized strings

**Files:**
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

**Interfaces:**
- Produces 6 `LocalizedStringKey`s consumed by Task 2: `ai.empty.title_ready`, `ai.empty.title_setup`, `ai.empty.subtitle_ready`, `ai.empty.subtitle_setup`, `ai.empty.run_hint`, `ai.ready`.

- [ ] **Step 1: Insert the keys**

Run this from the repo root. It inserts the six entries right after the `"strings" : {` line (always-valid JSON regardless of key ordering; Xcode re-sorts on next save). It refuses to double-insert.

```bash
python3 - <<'PY'
import io
f = "NemoNotch/Resources/Localizable.xcstrings"
s = open(f, encoding="utf-8").read()
if "ai.empty.title_ready" in s:
    print("already present; no change"); raise SystemExit(0)

def entry(key, en, zh):
    return (
f'''    "{key}" : {{
      "localizations" : {{
        "en" : {{
          "stringUnit" : {{
            "state" : "translated",
            "value" : "{en}"
          }}
        }},
        "zh-Hans" : {{
          "stringUnit" : {{
            "state" : "translated",
            "value" : "{zh}"
          }}
        }}
      }}
    }},
''')

block = "".join([
    entry("ai.empty.run_hint",
          "Run claude, gemini, or opencode in a terminal — sessions appear here.",
          "在终端运行 claude、gemini 或 opencode — 会话会自动出现在这里。"),
    entry("ai.empty.subtitle_ready", "Waiting for your next session", "等待下一个会话"),
    entry("ai.empty.subtitle_setup", "Enable a CLI to see live sessions", "启用一个 CLI 以查看实时会话"),
    entry("ai.empty.title_ready", "AI Console", "AI 控制台"),
    entry("ai.empty.title_setup", "Set up AI monitoring", "设置 AI 监控"),
    entry("ai.ready", "Ready", "就绪"),
])

marker = '  "strings" : {\n'
i = s.index(marker) + len(marker)
s = s[:i] + block + s[i:]
open(f, "w", encoding="utf-8").write(s)
print("inserted 6 keys")
PY
```

- [ ] **Step 2: Verify the file is still valid JSON and the keys exist**

Run:
```bash
python3 -c "import json; d=json.load(open('NemoNotch/Resources/Localizable.xcstrings',encoding='utf-8')); ks=['ai.empty.title_ready','ai.empty.title_setup','ai.empty.subtitle_ready','ai.empty.subtitle_setup','ai.empty.run_hint','ai.ready']; print('valid JSON,', sum(k in d['strings'] for k in ks), '/6 keys present'); print([k for k in ks if k not in d['strings']] or 'all present')"
```
Expected: `valid JSON, 6 /6 keys present` and `all present`.

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Resources/Localizable.xcstrings
git commit -m "feat(ai): add empty-console localized strings"
```

---

## Task 2: emptyConsole view

**Files:**
- Modify: `NemoNotch/Tabs/AIChatTab.swift`

**Interfaces:**
- Consumes (existing, unchanged): `claudeKind`/`geminiKind`/`opencodeKind: ProviderCardKind`, `hasAnyReadyProvider: Bool`, `allSessions`, `serverStatus`, `sourceIcon(_:size:)`, `sourceTint(_:)`, `notchCard(radius:fill:)`, `appSettings`, `aiService`. Keys from Task 1.
- Produces: `emptyConsole` view replacing the two old empty branches.

- [ ] **Step 1: Add the `heroBreathe` state property**

In `NemoNotch/Tabs/AIChatTab.swift`, find the existing `@State` declarations near the top of `struct AIChatTab` (currently `@State private var selectedSessionId: String?` and `@State private var showContextDetail = false`, around lines 12-13). Add directly below them:

```swift
    @State private var heroBreathe = false
```

- [ ] **Step 2: Simplify the `body` empty-branch**

Replace the current `body` (lines ~137-147):

```swift
    var body: some View {
        if !hasAnyReadyProvider, hasRecoveryCards, allSessions.isEmpty {
            recoveryCards
        } else if allSessions.isEmpty {
            idleState
        } else if let sessionId = selectedSessionId, let session = sessionById(sessionId) {
            chatDetail(session: session)
        } else {
            sessionList
        }
    }
```

with:

```swift
    var body: some View {
        if allSessions.isEmpty {
            emptyConsole
        } else if let sessionId = selectedSessionId, let session = sessionById(sessionId) {
            chatDetail(session: session)
        } else {
            sessionList
        }
    }
```

- [ ] **Step 3: Replace `recoveryCards`, `providerCard`, and `idleState` with the new views**

Delete these three contiguous members (currently `recoveryCards` at ~149-190, `providerCard` at ~192-231, `idleState` at ~233-244) and replace that whole span with the following. Keep `serverStatus` (immediately after) untouched.

```swift
    // MARK: - Empty state

    private var emptyConsole: some View {
        VStack(spacing: 16) {
            emptyHero
            providerStatusList
            emptyFooter
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 12)
    }

    private var emptyHero: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [NotchTheme.accent, NotchTheme.accentHot],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 48, height: 48)
                .overlay {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(heroBreathe ? 0.55 : 1.0)
                }
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        heroBreathe = true
                    }
                }
            Text(hasAnyReadyProvider ? "ai.empty.title_ready" : "ai.empty.title_setup")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(NotchTheme.textPrimary)
            Text(hasAnyReadyProvider ? "ai.empty.subtitle_ready" : "ai.empty.subtitle_setup")
                .font(.system(size: 12))
                .foregroundStyle(NotchTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var providerStatusList: some View {
        VStack(spacing: 0) {
            providerStatusRow(source: .claude, name: "Claude Code", kind: claudeKind) {
                appSettings.claudeEnabled = true
                if !aiService.claudeProvider.isHookInstalled {
                    aiService.claudeProvider.installHooks()
                }
            }
            Divider().overlay(NotchTheme.textTertiary.opacity(0.15))
            providerStatusRow(source: .gemini, name: "Gemini CLI", kind: geminiKind) {
                appSettings.geminiEnabled = true
                if !aiService.geminiProvider.isHookInstalled {
                    aiService.geminiProvider.installHooks()
                }
            }
            Divider().overlay(NotchTheme.textTertiary.opacity(0.15))
            providerStatusRow(source: .opencode, name: "opencode", kind: opencodeKind) {
                appSettings.opencodeEnabled = true
                if !aiService.opencodeProvider.isHookInstalled {
                    aiService.opencodeProvider.installHooks()
                }
            }
        }
        .notchCard(radius: 10, fill: NotchTheme.surface)
    }

    @ViewBuilder
    private func providerStatusRow(
        source: AISource,
        name: String,
        kind: ProviderCardKind,
        onAction: @escaping () -> Void
    ) -> some View {
        let isPassive = kind == .reenable
        HStack(spacing: 10) {
            sourceIcon(source, size: 16)
                .opacity(isPassive ? 0.6 : 1.0)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPassive ? NotchTheme.textSecondary : NotchTheme.textPrimary)
            Spacer(minLength: 8)
            switch kind {
            case .ready:
                HStack(spacing: 5) {
                    Circle()
                        .fill(sourceTint(source))
                        .frame(width: 6, height: 6)
                    Text("ai.ready")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(NotchTheme.textSecondary)
                }
            case .install:
                Button(action: onAction) {
                    Text("ai.install_hooks")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(NotchTheme.accent.opacity(0.18)))
                .clipShape(Capsule())
                .foregroundStyle(NotchTheme.accent)
            case .reenable:
                Button(action: onAction) {
                    Text("ai.enable")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(Capsule().stroke(NotchTheme.accent.opacity(0.55), lineWidth: 1))
                .clipShape(Capsule())
                .foregroundStyle(NotchTheme.accent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var emptyFooter: some View {
        VStack(spacing: 6) {
            if hasAnyReadyProvider {
                Text("ai.empty.run_hint")
                    .font(.system(size: 10))
                    .foregroundStyle(NotchTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            serverStatus
        }
    }
```

- [ ] **Step 4: Remove the now-unused `hasRecoveryCards`**

Delete the `hasRecoveryCards` computed property (currently lines ~52-54):

```swift
    private var hasRecoveryCards: Bool {
        claudeKind != .ready || geminiKind != .ready || opencodeKind != .ready
    }
```

(Leave `hasAnyReadyProvider` — `emptyConsole` uses it.)

- [ ] **Step 5: Build**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" 2>&1 | tail -8`
Expected: `** BUILD SUCCEEDED **`. If the compiler reports `recoveryCards`/`providerCard`/`idleState`/`hasRecoveryCards` still referenced somewhere, that reference is the old `body` — confirm Step 2 was applied. If it reports an unused-but-defined warning, ensure all four old members were fully removed.

- [ ] **Step 6: Manual check (no unit test — pure view code)**

Launch the app (or the `--uitest` screenshot harness if convenient). Verify both situations render:
- All providers ready, no sessions → hero tile with breathing sparkles, "AI Console" / "Waiting for your next session", a card with three rows each showing a tinted dot + "Ready", the run-hint line, and the green "Hook service ready" dot.
- At least one provider disabled/not-installed → "Set up AI monitoring" / "Enable a CLI to see live sessions", that provider's row shows an Install-hooks (filled) or Enable (outline) button and dims if disabled; ready rows still show "Ready".

(If you cannot launch the app in this environment, state that the build passed and the manual check is pending.)

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/Tabs/AIChatTab.swift
git commit -m "feat(ai): unified adaptive empty-state console for AI tab"
```

---

## Self-Review

**Spec coverage:**
- Unified `emptyConsole` replacing both empties → Task 2 Steps 2-3. ✓
- Adaptive title/subtitle on `hasAnyReadyProvider` → `emptyHero`. ✓
- Hero breathe (1.0↔0.55, 1.6s, autoreverse, forever) → `emptyHero` + `heroBreathe` state. ✓
- All three providers always shown, Ready-pill / Install / Enable by kind, disabled row dimmed → `providerStatusList` + `providerStatusRow`. ✓
- Run hint only when `hasAnyReadyProvider`; server status always → `emptyFooter`. ✓
- Inner width cap 360, centered → `emptyConsole`. ✓
- Action closures match old `recoveryCards` → `providerStatusList`. ✓
- Remove `idleState`/`recoveryCards`/`providerCard`/`hasRecoveryCards` → Task 2 Steps 3-4. ✓
- 6 strings (en+zh) → Task 1. ✓

**Placeholder scan:** No TBD/TODO; all steps show exact code/commands.

**Type consistency:** `ProviderCardKind` cases (`.ready/.install/.reenable`) match existing enum; `sourceIcon(_:size:)`, `sourceTint(_:)`, `serverStatus`, `notchCard(radius:fill:)`, `hasAnyReadyProvider`, `claudeKind/geminiKind/opencodeKind` all pre-exist and are used with their real signatures. String keys identical between Task 1 (defined) and Task 2 (consumed).
