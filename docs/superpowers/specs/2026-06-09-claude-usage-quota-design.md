# Claude Code Usage Quota Card — Design

**Date:** 2026-06-09
**Status:** Draft (awaiting user review)

## Goal

Surface Claude Code subscription usage inside NemoNotch: the **5-hour** and
**7-day** rolling-window quotas (utilization % + reset countdown), shown as a
compact card in `AIChatTab`. Ported in spirit from the reference project
`TermiPet` (`Source/Sources/TermiPetCore/UsageQuota.swift`), adapted to
NemoNotch's `@Observable` / `LifecycleAware` conventions and de-scoped to
**Claude Code only** (the sole provider with an official usage endpoint).

## Scope decisions (confirmed with user)

- **Provider:** Claude Code only. No `AIService` enum / multi-provider
  dictionary (TermiPet's Codex/Copilot scaffold is dropped per YAGNI). Adding a
  future provider would follow NemoNotch's existing protocol-first pattern.
- **Surface:** one compact card in `AIChatTab`, rendered above the session list
  when `claudeEnabled`.
- **Refresh:** fetch on tab-visible (`setActive(true)`); manual refresh button;
  **throttle** — non-forced fetch within 60s of the last is skipped; a 5-minute
  timer auto-refreshes while the tab is visible; timer stops on
  `setActive(false)`.

## Verified facts (probed on this machine, 2026-06-09)

1. **Credential storage:** `~/.claude/.credentials.json` does **not** exist
   here; the live credential is in the macOS Keychain as a generic password,
   `service = "Claude Code-credentials"`, `account = <username>`. Keychain is
   therefore the **primary** path; the file is a portability fallback.
2. **Blob schema:** `{ claudeAiOauth: { accessToken, expiresAt (ms epoch),
   refreshToken, scopes, subscriptionType, rateLimitTier }, mcpOAuth }`.
   `expiresAt` is a 13-digit millisecond timestamp.
3. **Endpoint:** `GET https://api.anthropic.com/api/oauth/usage` with
   `Authorization: Bearer <token>` + `anthropic-beta: oauth-2025-04-20` returns
   HTTP 200 and this shape:
   ```
   five_hour:         { utilization: 6.0,  resets_at: "2026-06-09T08:00:00.858062+00:00" }
   seven_day:         { utilization: 3.0,  resets_at: "2026-06-15T13:00:00.858087+00:00" }
   seven_day_opus:    null
   seven_day_sonnet:  { utilization: 0.0,  resets_at: "..." }
   seven_day_oauth_apps, seven_day_cowork, tangelo, extra_usage, ... (ignored)
   ```
4. **⚠️ `resets_at` format gotcha:** values carry **6-digit fractional seconds
   and a `+00:00` offset** (`...00.858062+00:00`). TermiPet parses these with a
   bare `ISO8601DateFormatter()`, which does **not** enable
   `.withFractionalSeconds` and would return `nil` → countdown renders `--`.
   This port **must** parse robustly (fractional seconds enabled, microseconds
   tolerated). This is the one behavioral fix vs. the reference.

## Architecture

NemoNotch is a single app target (no `Core` module split), so pure logic lives
in `Models/` for testability and the networking/state lives in `Services/`.

### 1. `NemoNotch/Models/UsageQuota.swift` — pure, unit-tested

```swift
enum CredentialStatus { case valid, expired, notFound, parseError }

struct QuotaTier {            // one rolling window
    let windowKey: QuotaWindow   // .fiveHour / .sevenDay / .sevenDayOpus / .sevenDaySonnet
    let utilization: Double      // 0...100
    let resetsAt: Date?
}

struct ClaudeUsageQuota {
    let status: CredentialStatus
    let tiers: [QuotaTier]
    let fetchedAt: Date
    let errorMessage: String?
}

enum UsageCredentialParser {
    static func parseClaudeCredentials(data: Data, now: Date) throws -> UsageCredential
    // claudeAiOauth.accessToken + expiresAt(ms) expiry check (ported)
}

enum UsageQuotaParser {
    static func parseClaudeCodeQuota(data: Data, fetchedAt: Date) throws -> ClaudeUsageQuota
    // decodes five_hour/seven_day/seven_day_opus/seven_day_sonnet, compactMap drops nulls
    // resets_at parsed via robust ISO8601 (withFractionalSeconds + microsecond truncation)
}

enum UsageQuotaFormatter {
    static func countdown(until: Date, now: Date) -> String   // "6d3h" / "4h12m" / "<1m" / reset
}
```

`QuotaWindow` is an enum (not a raw label string) so the view maps it to a
localized label — `5h` / `7d` / `7d Opus` / `7d Sonnet`.

### 2. `NemoNotch/Services/UsageQuotaService.swift` — `@MainActor @Observable`, `LifecycleAware`

- State: `private(set) var quota: ClaudeUsageQuota?`, `private(set) var isRefreshing`.
- `readCredential()`: Keychain `SecItemCopyMatching` for
  `service = "Claude Code-credentials"` (mirroring the pattern already in
  `OpenClawService`); on miss, fall back to `~/.claude/.credentials.json`.
- `fetch()`: builds the authed `URLRequest` (10s timeout), `URLSession.shared`,
  maps 401 → `.expired`, non-2xx → valid-with-errorMessage, else parse.
- `refresh(force:)`: skip if `!force && lastFetched within 60s`.
- `setActive(_:)`: on `true` → initial `refresh()` + start 5-min `Timer`; on
  `false` → invalidate timer.
- `LogService` at init, fetch start/success/failure, credential miss, expiry,
  HTTP error (category `"UsageQuotaService"`).

### 3. `NemoNotch/Tabs/UsageQuotaCardView.swift`

Compact card: title row (status dot + refresh button with spin animation), then
one row per tier — `label | capsule progress bar | NN% | countdown`. Color
ramp: ≥90 red, ≥70 orange, else green (ported). Empty/error states:
not-logged-in, login-required, reading, error — all localized. Bound to the
service lifecycle via `.activates(quotaService)`.

### 4. Wiring

- `AIChatTab`: render the card above the session list when `claudeEnabled`.
- `AppDelegate` (`NemoNotchApp.swift`): construct `UsageQuotaService`, inject via
  `.environment(...)` in **both** environment chains (MenuBar + notch window).
- `Localizable.xcstrings`: add `quota.*` keys (zh + en).

### 5. Tests — `NemoNotchTests/UsageQuotaTests.swift` (Swift Testing, TDD-first)

- `parseClaudeCodeQuota`: normal (the verified real payload incl. the
  microsecond `resets_at`), null tiers dropped, malformed JSON → throws.
- `parseClaudeCredentials`: valid / expired (`expiresAt` in past) / missing token.
- `countdown`: days+hours, hours+minutes, minutes-only, `<1m`, already-reset.
- **Regression test for the fractional-second `resets_at`** — must parse to a
  non-nil `Date`.

## Out of scope

`extra_usage` overage display, Codex/Copilot, collapsed-notch badge, Settings
page. Each is an additive follow-up if wanted later.

## Docs to update (per CLAUDE.md)

`README.md`, `README_CN.md`, `CLAUDE.md` (service list + AI architecture note),
and `docs/macos-cookbook.md` only if a new Keychain/private-API technique is
introduced (the Keychain read pattern already exists, so likely a cross-ref
rather than a new entry).
