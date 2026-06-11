# Quota Keychain — button-gated authorization

**Date:** 2026-06-11
**Branch:** `feature/quota-keychain-no-prompt`
**Status:** Approved

## Problem

`UsageQuotaService` reads CLI-owned Keychain items (`Claude Code-credentials`,
`Codex Auth`) to fetch usage quotas. A prior change made the read
non-interactive so it no longer pops the macOS consent dialog on AI-tab open —
but a non-interactive read of an *unauthorized* item returns `nil`, which is
indistinguishable from "no credential at all". The user never learns they could
authorize.

Desired UX (consistent with the app's existing `PermissionCard` pattern for
Calendar / Location / Automation / Notification): when an item exists but this
app isn't authorized, **show a 授权 (Authorize) button**; the system dialog
appears **only when the user clicks it**. Never auto-prompt.

## Scope

Quota Keychain access only. System-permission flows already follow this pattern
and are untouched.

## Design

### 1. Model — `NemoNotch/Models/UsageQuota.swift`

Add one case to `CredentialStatus`:

```swift
case needsAuthorization   // Keychain item exists but this app isn't authorized yet
```

### 2. Service — `NemoNotch/Services/UsageQuotaService.swift`

**a. Preflight probe** (new) — attributes-only + no-UI, 4-way outcome:

```swift
private enum KeychainProbe { case authorized, needsAuthorization, notFound, failure }
private func keychainProbe(service: String) -> KeychainProbe
```

Mapping of `SecItemCopyMatching` status:
- `errSecSuccess` → `.authorized`
- `errSecInteractionNotAllowed` → `.needsAuthorization`
- `errSecItemNotFound` → `.notFound`
- else → `.failure`

Query uses `kSecReturnAttributes: true` (NOT `kSecReturnData` — requesting the
secret payload can itself surface the legacy prompt) plus `applyNoUI`.

**b. `readClaudeCredential` / `readCodexCredential`** — file-first stays. When no
usable file, branch on the probe:
- `.authorized` → existing no-UI `keychainBlob` read → parse → `.valid`
- `.needsAuthorization` → `UsageCredential(token: nil, status: .needsAuthorization)`
- `.notFound` / `.failure` → `UsageCredential(token: nil, status: .notFound)`

**c. `fetchClaude` / `fetchCodex`** — when the credential is `.needsAuthorization`,
return `ProviderUsageQuota(status: .needsAuthorization)` immediately, with **no
network call**.

**d. `codexCredentialPresent()`** — return `true` when the file exists OR the
probe is `.authorized` or `.needsAuthorization` (otherwise the Codex section
hides and the button never shows). `.notFound`/`.failure` → absent.

**e. New `func authorize(_ provider: QuotaProvider) async`** — the button action:
- Performs **one interactive** Keychain read (a query *without* the no-UI flags)
  for that provider's service, run off the main actor (the blocking system
  dialog must not freeze MainActor).
- On success → `await refresh(force: true)` (subsequent non-interactive reads
  now succeed silently).
- On deny/cancel → no state change; stays `.needsAuthorization`.

### 3. UI

- **`UsageQuotaCardView.providerSection`** — when `status == .needsAuthorization`,
  render an inline 授权 button (accent capsule, matching `PermissionCard`'s
  button style) instead of the status text →
  `Task { await service.authorize(provider) }`.
- **`UsageQuotaCompactView`** — the same state shows a small tappable 授权
  affordance that calls `authorize` directly.
- **Localization** (`NemoNotch/Resources/Localizable.xcstrings`):
  - `quota.authorize` — en "Authorize" / zh-Hans "授权"
  - `quota.status.needs_authorization` — en "Authorization needed" / zh-Hans "需要授权"

## Non-goals

- **No prompt cooldown** (CodexBar has one): unnecessary because we never
  auto-prompt — the button is the only trigger, so no prompt storm is possible.
- No changes to system-permission flows.
- `.failure` probe outcome is treated as `.notFound` to avoid a dead button that
  can't succeed.

## Known behavior

If the user picks "Allow Once" (not "Always Allow") in the system dialog, the
next entry returns to `.needsAuthorization`. This is macOS keychain ACL behavior
and is expected.

## Testing

The new logic (probe, `authorize`, the probe→status branches) lives entirely
inside private `@MainActor` methods that call `SecItem*` / the network — exactly
the Keychain/integration-bound code the project's testing convention says to
skip (it needs real macOS authorization state and is flaky). The OSStatus→probe
and probe→`CredentialStatus` mappings are trivial 1:1 switches; exposing them
purely to assert a rename carries no defect-catching value and would add
DI scaffolding the design doesn't otherwise need.

Coverage relied on instead:
- The existing `UsageQuotaTests` suite (parsers/formatters) still passes with the
  new `CredentialStatus` case — confirms no regression.
- Build verifies the exhaustive `switch` over `CredentialStatus` was updated in
  the UI (`statusKey`).
- Manual verification of the actual prompt behavior (run the app, open AI tab,
  confirm no dialog; click 授权, confirm the dialog appears once).

If injectable coverage is wanted later, extract a credential-source protocol
(file reader + keychain probe) and inject fakes — deferred as out of scope.
