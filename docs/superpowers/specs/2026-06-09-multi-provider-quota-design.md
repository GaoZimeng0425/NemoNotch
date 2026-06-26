# Multi-Provider Usage Quota (Claude + Codex) — Design

**Date:** 2026-06-09
**Status:** Draft (awaiting user review)
**Builds on:** `docs/plans/2026-06-09-claude-usage-quota-design.md` (Claude-only, now merged to develop).

## Goal

Generalize the just-shipped Claude-only usage-quota card into a **multi-provider**
card showing **Claude Code** and **Codex** quotas. Claude shows its 5h/7d
windows (unchanged); Codex shows its rate-limit windows (5h/7d on paid plans, a
single 30-day window on the free plan). Gemini is explicitly **out of scope this
round** (it needs OAuth token refresh + client-secret extraction + project
resolution — a separate effort).

## Scope decisions (confirmed with user)

- **Providers this round:** Claude + Codex only. Gemini deferred.
- **Codex section visibility:** shown **only when a Codex credential is detected**
  (`~/.codex/auth.json` exists or Keychain `Codex Auth` present). Users without
  Codex never see it. No `codexEnabled` setting.
- **Card visibility:** the card shows when `claudeEnabled` **OR** a Codex
  credential is present.
- **Codex token:** read the stored token and call; `401 → re-login`. No proactive
  refresh this round (the stored token was verified working). Refresh is future
  hardening, bundled with the Gemini effort.

## Verified facts (probed on this machine, 2026-06-09)

- `~/.codex/auth.json` exists (mode 600). Shape:
  `{ auth_mode: "chatgpt", tokens: { access_token, account_id, id_token, refresh_token }, last_refresh }`.
  Keychain `Codex Auth` not present here → **file path is primary**, Keychain is fallback.
- `GET https://chatgpt.com/backend-api/wham/usage` with `Authorization: Bearer`,
  `ChatGPT-Account-Id: <account_id>`, `User-Agent`, `Accept: application/json`
  → HTTP 200. Response (this account, `plan_type: free`):
  ```
  rate_limit:
    primary_window:   { used_percent: 7, limit_window_seconds: 2592000, reset_at: 1782973688 }
    secondary_window: null
  ```
  `limit_window_seconds`: 18000=5h, 604800=7d, 2592000=30d. Paid plans return
  both primary (5h) + secondary (7d). `used_percent` is an int here; decode as Double.

## Reference: what we borrow from CodexBar (`/Users/gaozimeng/Learn/macOS/CodexBar`)

CodexBar is a mature, descriptor-driven multi-provider menu-bar app. We borrow
the **good small ideas** and deliberately skip its heavyweight framework:

| CodexBar mechanism | Decision | Rationale |
|---|---|---|
| `RateWindow` shape (`usedPercent`, `windowMinutes`, `resetsAt`) | **Borrow** | Cleaner canonical tier; use **minutes** as the window unit |
| `backfillingResetTime(from cached:)` — carry forward reset when API omits it | **Borrow** (minimal) | Fixes the documented "100% → reset/remaining omitted → countdown shows `--`" failure |
| `CodexRateWindowNormalizer` (300min=session, 10080min=weekly; order session→weekly) | **Borrow** | Deterministic Codex window ordering regardless of API order |
| Codex endpoint + headers | **Borrow** (already verified identical) | — |
| Descriptor + macro registry + multi-strategy pipeline (CLI/web/OAuth/probe) | **Skip** | We have 2 providers + one card; a `[QuotaProvider: ProviderUsageQuota]` dict suffices (YAGNI) |
| WKWebView/cookie/PTY scraping, authority reconciliation, Codable cache, identity siloing | **Skip** | Not needed |
| `CodexTokenRefresher` (proactive OAuth refresh) | **Skip this round** | Stored token verified working; refresh bundled with Gemini |

## Architecture

Single app target, same layering as the Claude-only feature: pure logic in
`Models/`, networking/state in `Services/`, view in `Tabs/`.

### 1. `NemoNotch/Models/UsageQuota.swift` (modify)

```swift
enum CredentialStatus { case valid, expired, notFound, parseError }   // unchanged

enum QuotaProvider: String, CaseIterable, Sendable {
    case claude, codex
    var displayName: String { self == .claude ? "Claude Code" : "Codex" }  // brand names, verbatim
}

// Named Claude windows preserve existing localized labels; .rolling carries
// Codex's arbitrary duration in MINUTES (CodexBar's unit).
enum QuotaWindow: Hashable, Sendable {
    case fiveHour
    case sevenDay
    case sevenDayOpus
    case sevenDaySonnet
    case rolling(minutes: Int)
}

struct QuotaTier: Equatable, Sendable {
    let window: QuotaWindow
    let utilization: Double      // 0...100 (used percent)
    let resetsAt: Date?
    // Borrowed from CodexBar RateWindow.backfillingResetTime
    func backfillingReset(from cached: QuotaTier?, now: Date) -> QuotaTier
}

struct ProviderUsageQuota: Equatable, Sendable {   // was ClaudeUsageQuota
    let provider: QuotaProvider
    let status: CredentialStatus
    let tiers: [QuotaTier]
    let fetchedAt: Date
    let errorMessage: String?
}

struct UsageCredential: Equatable, Sendable {
    let token: String?
    let accountID: String?       // NEW — Codex ChatGPT-Account-Id header
    let status: CredentialStatus
    let message: String?
}

enum UsageCredentialParser {
    static func parseClaudeCredentials(data:now:) throws -> UsageCredential   // unchanged (accountID nil)
    static func parseCodexCredentials(data:now:) throws -> UsageCredential    // NEW
    // auth_mode=="chatgpt" → token=tokens.access_token, accountID=tokens.account_id, .valid
    // auth_mode != chatgpt → .notFound ; missing token → .parseError
}

enum UsageQuotaParser {
    static func parseClaudeCodeQuota(data:fetchedAt:) throws -> ProviderUsageQuota  // provider:.claude, windows unchanged
    static func parseCodexQuota(data:fetchedAt:) throws -> ProviderUsageQuota       // NEW
    // decode rate_limit.primary_window/secondary_window → QuotaTier(.rolling(min: limit_window_seconds/60), used_percent, reset_at)
    // drop nulls; apply CodexRateWindowNormalizer ordering (session 300 → weekly 10080 → others)
    static func parseResetDate(_:) -> Date?   // unchanged
}

enum UsageQuotaFormatter {
    static func countdown(until:now:) -> CountdownResult        // unchanged
    static func windowLabel(minutes: Int) -> String            // NEW: 300→"5h", 10080→"7d", 43200→"30d", else Nd/Nh/Nm
}

enum CodexRateWindowNormalizer {                               // NEW (borrowed)
    // role(minutes): 300=session, 10080=weekly, else unknown; reorder so session precedes weekly
    static func order(_ tiers: [QuotaTier]) -> [QuotaTier]
}
```

`windowLabel(minutes:)`: `m % 1440 == 0 → "\(m/1440)d"`; else `m % 60 == 0 → "\(m/60)h"`; else `"\(m)m"`. (300→"5h", 10080→"7d", 43200→"30d".)

### 2. `NemoNotch/Services/UsageQuotaService.swift` (modify)

- `private(set) var quotas: [QuotaProvider: ProviderUsageQuota]` (replaces `quota`).
- `private(set) var hasCodexCredential: Bool` — computed in `init()` (file exists **or** Keychain `Codex Auth` present) so the UI gate is correct from launch; re-evaluated on each fetch.
- `refresh(force:)`: same throttle (60s) + `isRefreshing` guard. Fetches **concurrently**:
  `async let claude = fetchClaude()`, and `if hasCodexCredential { async let codex = fetchCodex() }`.
  Applies `backfillingReset` against the previous `quotas` per provider/window, then assigns.
- `fetchClaude()` → `ProviderUsageQuota` (existing logic; provider `.claude`).
- `fetchCodex()`: read Codex credential (file `~/.codex/auth.json`, Keychain `Codex Auth` fallback),
  `GET wham/usage` with `Bearer` + `ChatGPT-Account-Id` + `User-Agent: NemoNotch` + `Accept`,
  401 → `.expired`, non-2xx → `.valid`+errorMessage, else `parseCodexQuota`.
- `keychainBlob(service:)` generalized to take the service name (`"Claude Code-credentials"` / `"Codex Auth"`).
- 5-min timer + `LifecycleAware` + `deinit` unchanged.

### 3. `NemoNotch/Tabs/UsageQuotaCardView.swift` (modify)

- Add `@Environment(AppSettings.self) private var appSettings`.
- Compute ordered visible providers: `.claude` if `appSettings.claudeEnabled`; `.codex` if `service.hasCodexCredential`.
- For each provider: a section header `Text(verbatim: provider.displayName)` + either its tier rows
  (`quotas[p].status == .valid && !tiers.isEmpty`) or a localized status line. Small spacing between sections.
- `label(for:)`: named windows → existing localized keys (`quota.window.5h/7d/7d_opus/7d_sonnet`);
  `.rolling(m)` → `Text(verbatim: UsageQuotaFormatter.windowLabel(minutes: m))`.
- Refresh button now refreshes all providers (unchanged call: `service.refresh(force: true)`).

### 4. `NemoNotch/Tabs/AIChatTab.swift` (modify)

- Add `@Environment(UsageQuotaService.self) private var quotaService`.
- Gate: `if appSettings.claudeEnabled || quotaService.hasCodexCredential { UsageQuotaCardView() }`.

### 5. Tests — `NemoNotchTests/UsageQuotaTests.swift` (modify)

- Rename `ClaudeUsageQuota` → `ProviderUsageQuota` refs; assert `provider == .claude` on Claude parse.
- `parseCodexQuota` free-tier (verified payload: primary 30d, secondary null) → 1 tier, `.rolling(43200)`, util 7, resetsAt non-nil, provider `.codex`.
- `parseCodexQuota` paid-tier mock with windows **out of order** (weekly first) → normalized `[.rolling(300), .rolling(10080)]`.
- `windowLabel(minutes:)`: 300→"5h", 10080→"7d", 43200→"30d", 1440→"1d", 90→"90m".
- `parseCodexCredentials`: valid (token+accountID), missing token → `.parseError`, `auth_mode != chatgpt` → `.notFound`.
- `backfillingReset`: tier with nil reset + cached future reset → carries reset; cached past reset → unchanged.

### Localization

**No catalog changes.** Claude window labels reuse the existing `quota.window.*`
keys (preserves zh `5小时`/`7天`). Codex window labels are verbatim duration
strings (`5h`/`7d`/`30d`). Provider headers are brand names (verbatim). Codex
section reuses existing `quota.status.*` keys.

### Wiring note

`AppDelegate` needs **no change** — `UsageQuotaService` is already constructed
and injected into the NotchView chain.

## Out of scope

Gemini quota (separate effort: token refresh + client-secret extraction +
project resolution + per-model buckets), proactive Codex token refresh, Codex
session/CLI detection, collapsed-notch badge, Settings page.

## Docs to update

`CLAUDE.md` (service node → multi-provider), `README.md`, `README_CN.md`
(quota bullet mentions Codex).
