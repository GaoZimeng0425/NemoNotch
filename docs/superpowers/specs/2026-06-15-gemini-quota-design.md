# Gemini Usage Quota — Design

**Date:** 2026-06-15
**Branch:** `feature/gemini-quota`
**Status:** Approved (design), pending implementation plan

## Goal

Show Gemini's usage quota in the AI tab's quota card/meters, alongside the
existing Claude Code and Codex sections — same visual treatment, gated by the
existing `AppSettings.geminiEnabled` toggle.

This design **ports CodexBar's production-tested `GeminiStatusProbe`** (at
`/Users/gaozimeng/Learn/macOS/CodexBar/Sources/CodexBarCore/Providers/Gemini/GeminiStatusProbe.swift`)
into NemoNotch's `UsageQuotaService` shape. Where a decision had a fork, we
chose CodexBar parity.

## Background / Feasibility

Gemini (free-tier, personal Google account) **does** expose usage quota via the
Cloud Code private API. The path is more involved than Claude/Codex:

- **Credential:** `~/.gemini/oauth_creds.json` — a plain file (mode 0600,
  readable by the user's own GUI app). **No Keychain involved**, so none of the
  Claude/Codex Keychain-authorize dance is needed. Contains `access_token`,
  `id_token`, `refresh_token`, `expiry_date` (ms epoch).
- **Auth-type guard:** read `~/.gemini/settings.json` →
  `security.auth.selectedType`. Block `api-key` and `vertex-ai` (this OAuth flow
  can't serve them); allow `oauth-personal` and `unknown` (absent file → try
  OAuth creds anyway). Surface a clear "not supported / not logged in" status.
- The stored `access_token` is short-lived (~1h) and is **typically already
  expired** when NemoNotch reads it, so unlike Claude/Codex
  ("read token → call"), Gemini **must refresh the token first**.
- The quota endpoint requires a `project` field, resolved via `loadCodeAssist`
  (with a `cloudresourcemanager` fallback, and an empty-body last resort).

**Three-call flow** (all `POST`, `Authorization: Bearer <accessToken>`):

1. **Refresh token** → `POST https://oauth2.googleapis.com/token`
   Content-Type `application/x-www-form-urlencoded`, body:
   `client_id`, `client_secret`, `refresh_token`, `grant_type=refresh_token`.
   On HTTP 200, parse `access_token` (+ `expires_in`, `id_token`) and
   **write the new values back** to `oauth_creds.json` (atomic) — matching what
   gemini-cli itself does, keeping NemoNotch and the CLI in sync and avoiding
   redundant refreshes. Only refresh when `access_token` is missing or
   `expiry_date < now`.
2. **Resolve project** → `POST .../v1internal:loadCodeAssist`
   Body: `{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}`.
   Response: `currentTier.id`, `cloudaicompanionProject` (string, or object with
   `id`/`projectId`). Take the project; on failure fall back to
   `GET https://cloudresourcemanager.googleapis.com/v1/projects` and pick a
   project whose id has the `gen-lang-client` prefix or a `generative-language`
   label. If still none, send the quota request with an empty body `{}`.
3. **Fetch quota** → `POST .../v1internal:retrieveUserQuota`
   Body: `{"project":"<id>"}` (or `{}`).
   Response: `{ buckets: [ { modelId, tokenType, remainingFraction, resetTime } ] }`.

Base: `https://cloudcode-pa.googleapis.com/v1internal`.

**OAuth client_id/secret — extracted at runtime from the installed gemini-cli**
(NOT hardcoded), matching CodexBar so a Google key rotation doesn't break us:

- Locate the `gemini` binary: PATH lookup (`which gemini` equivalent) →
  resolve symlinks (this machine: bun → `.../@google/gemini-cli/bundle/gemini.js`).
- Read the OAuth constants `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET` from the
  CLI's JavaScript, trying in order:
  1. **Legacy static paths** — cheap file reads for Homebrew / npm-sibling /
     Nix / npm-nested layouts (`dist/src/code_assist/oauth2.js`).
  2. **Package-root walk** — ascend ≤8 dirs from the resolved binary looking
     for `package.json` with `name == "@google/gemini-cli"`, then read
     `oauth2.js`.
  3. **Bundle scan** — BFS the `bundle/` dir from `gemini.js` following relative
     `./*.js` imports (then any sibling `*.js`), regex-matching the two
     constants. (This machine's bun install hits this path.)
- Regex (from CodexBar):
  `OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]` and
  `OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]`.
- **Skip** CodexBar's fnm-subprocess resolution (`fnm exec npm root -g`) for
  now — note it as a known gap; falls through to "can't refresh → not logged in".

**Risk:** some free tiers return empty/partial `buckets` (gemini-cli issue
#14883). Degrade gracefully to the existing "no data" status — never error the
whole card.

Sources: CodexBar `GeminiStatusProbe.swift`; gemini-cli issues #27363, #14883.

## Data Model — `Models/UsageQuota.swift`

- `QuotaProvider`: add `.gemini`, `displayName = "Gemini"`.
- `QuotaWindow`: add `case gemini(label: String)`. Gemini buckets are per-model
  daily quotas, not rolling windows, so the case carries a short label (model
  short name, e.g. `"2.5 Pro"`, `"Flash"`). `String` keeps the enum `Hashable`.
- New `GeminiOAuthCredential` struct + `UsageCredentialParser.parseGeminiCredentials(data:now:)`
  reading `access_token` / `refresh_token` / `expiry_date`. (No `id_token` —
  account email/plan display is out of scope, so the JWT is never needed.)
- `UsageQuotaParser.parseGeminiQuota(data:fetchedAt:)`:
  - Decode `buckets[]`.
  - **Collapse per model** (CodexBar behavior): group by `modelId`, keep the
    **lowest `remainingFraction`** (most-constrained token type) per model. No
    per-token-type rows.
  - `utilization = (1 - remainingFraction) * 100` (clamped 0...100;
    missing `remainingFraction` → bucket skipped).
  - `resetsAt` from `resetTime` via existing `parseResetDate` (RFC3339).
  - Order rows by **utilization descending** (most-constrained first → compact
    view's primary slot shows the tightest meter).
  - Empty/partial buckets → `.valid` with no tiers (existing "no data" UI).
- Model short-name helper: `gemini-2.5-pro → "2.5 Pro"`, `gemini-2.5-flash →
  "2.5 Flash"`, `*flash-lite* → "Flash Lite"`, else strip the `gemini-` prefix.

## Service — `Services/UsageQuotaService.swift`

- Expose `hasGeminiCredential` (file exists at `~/.gemini/oauth_creds.json` AND
  auth-type guard passes), computed at init, mirroring `hasCodexCredential`.
  UI gate = `appSettings.geminiEnabled && service.hasGeminiCredential`.
- New `fetchGeminiIfPresent()` running the flow from Background:
  1. Auth-type guard (settings.json) → unsupported = `.notFound` + message.
  2. Read + parse credential (file only — no Keychain path needed).
  3. Refresh token if missing/expired → write back to `oauth_creds.json`.
  4. loadCodeAssist → project (+ cloudresourcemanager fallback → `{}`).
  5. retrieveUserQuota → `parseGeminiQuota`.
- Wire into existing `refresh(force:)`: add `async let geminiTask`, merge into
  the `next` dict, apply the existing `backfilled(...)` reset carry-forward.
- HTTP 401 anywhere → `.expired` ("Re-login required"); other failures degrade
  per-step with logs.
- Credential extraction lives in a dedicated helper
  (`GeminiOAuthClientLocator` or similar) so the binary-locating / JS-parsing
  bulk stays out of the service body.

## UI — `Tabs/UsageQuotaCardView.swift`

- `visibleProviders` (full card + compact): append `.gemini` when
  `appSettings.geminiEnabled && service.hasGeminiCredential`.
- `label(for:)` (full card) and `windowShortLabel(_:)` (compact): handle
  `.gemini(label)` by returning the carried label verbatim.
- Compact `label(provider:tier:)`: provider initial `"G"` for Gemini.
- **Compact layout change:** up to **3** providers now (the "never exceeds two"
  assumption is gone). Change the compact `rows` rule to **one `.primary` row
  per visible provider (max 3 rows)**; keep the single-provider case showing
  primary + secondary. Update the stale comment.

## Configuration / Wiring

- `AppSettings.geminiEnabled` already exists (default `true`) — no change.
- `UsageQuotaService` is created in `NemoNotchApp.swift` with no args — no
  change to its construction.

## Logging (`category: "UsageQuotaService"`)

- `.info` on each step success (token refreshed + written back, project
  resolved, N tiers fetched).
- `.warn`/`.error` on: unsupported auth type, credential missing/unreadable,
  OAuth-client extraction failure, refresh HTTP failure, loadCodeAssist
  no-project, retrieveUserQuota HTTP/parse failure.

## Testing (Swift Testing, `NemoNotchTests/`)

- `parseGeminiQuota`: normal buckets; per-model collapse keeps the lowest
  fraction; utilization math + clamp; descending order; missing
  `remainingFraction` skipped; empty buckets → no tiers.
- `parseGeminiCredentials`: valid, missing refresh_token, expired, parse error.
- OAuth-client regex (`parseOAuthCredentials`) on sample `oauth2.js` content.
- Model short-name helper mapping (pro / flash / flash-lite / fallback).
- (Skip live network / OAuth / binary-location integration — same policy as
  Claude/Codex.)

## Docs to update (same commit as code)

- `CLAUDE.md`: replace the "Gemini quota is a planned follow-up" note with the
  implemented three-call flow + runtime OAuth-client extraction.
- `README.md`, `README_CN.md`: add Gemini to the quota feature description.
- `docs/macos-cookbook.md` §14.3: add an entry for Gemini's plain-file
  credential + runtime client-secret extraction + three-step quota flow
  (no Keychain, no new private API).

## Out of scope

- Account email / plan (Free/Paid/Workspace) display — CodexBar extracts these
  from the id_token JWT + `currentTier`, but NemoNotch's quota card has no slot
  for them, so we read neither.
- `onboardUser` long-running-operation provisioning for brand-new Gemini
  accounts (degrade to "no data").
- fnm-managed gemini installs (subprocess resolution) — known gap.
