# Multi-Provider Usage Quota (Claude + Codex) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize the Claude-only usage-quota card into a multi-provider card showing Claude Code **and** Codex quotas.

**Architecture:** Pure model/parsers in `Models/UsageQuota.swift` (unit-tested) gain a `QuotaProvider` dimension, a `.rolling(minutes:)` window, Codex parsing, a window normalizer, and reset-backfill (ideas borrowed from CodexBar). `UsageQuotaService` becomes `quotas: [QuotaProvider: ProviderUsageQuota]`, fetching Claude + Codex concurrently. The card renders one section per visible provider.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, `Security` (Keychain), `URLSession`, Swift Testing.

**Design spec:** `docs/plans/2026-06-09-multi-provider-quota-design.md`

**Working branch:** `feature/multi-provider-quota` (already checked out).

**Conventions:**
- Build: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -quiet 2>&1 | tail -8`
- Test: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests 2>&1 | tail -20`
- Xcode 16 auto-syncs source files — **never edit `project.pbxproj`** for these files (all already exist).
- Each task must leave the build green.

---

### Task 1: Model — add provider dimension + Codex account field (refactor, keep green)

Generalizes the existing types without behavior change. The struct rename touches the service too (it names the type), so the service is updated in the same task to stay compiling.

**Files:**
- Modify: `NemoNotch/Models/UsageQuota.swift`
- Modify: `NemoNotch/Services/UsageQuotaService.swift`
- Test: `NemoNotch/../NemoNotchTests/UsageQuotaTests.swift`

- [ ] **Step 1: Update the existing test to assert the new `provider` field**

In `NemoNotchTests/UsageQuotaTests.swift`, inside `parseQuotaRealPayload()`, add after `#expect(quota.status == .valid)`:

```swift
        #expect(quota.provider == .claude)
```

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests 2>&1 | tail -20`
Expected: FAIL — `value of type '...' has no member 'provider'`.

- [ ] **Step 3: Edit the model**

In `NemoNotch/Models/UsageQuota.swift`:

(a) Add the provider enum after `CredentialStatus`:

```swift
/// A usage-quota source.
enum QuotaProvider: String, CaseIterable, Sendable {
    case claude
    case codex

    /// Brand name shown as the section header (verbatim, not localized).
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}
```

(b) Rename `ClaudeUsageQuota` to `ProviderUsageQuota` and add the `provider` field:

```swift
/// Parsed usage quota for one provider (or an error state).
struct ProviderUsageQuota: Equatable, Sendable {
    let provider: QuotaProvider
    let status: CredentialStatus
    let tiers: [QuotaTier]
    let fetchedAt: Date
    let errorMessage: String?

    init(
        provider: QuotaProvider,
        status: CredentialStatus,
        tiers: [QuotaTier] = [],
        fetchedAt: Date = Date(),
        errorMessage: String? = nil
    ) {
        self.provider = provider
        self.status = status
        self.tiers = tiers
        self.fetchedAt = fetchedAt
        self.errorMessage = errorMessage
    }
}
```

(c) Add `accountID` to `UsageCredential`:

```swift
/// OAuth credential extracted from Keychain / credentials file.
struct UsageCredential: Equatable, Sendable {
    let token: String?
    let accountID: String?
    let status: CredentialStatus
    let message: String?

    init(token: String?, accountID: String? = nil, status: CredentialStatus, message: String? = nil) {
        self.token = token
        self.accountID = accountID
        self.status = status
        self.message = message
    }
}
```

(d) In `parseClaudeCodeQuota`, change the return type and value:

```swift
    static func parseClaudeCodeQuota(data: Data, fetchedAt: Date = Date()) throws -> ProviderUsageQuota {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let tiers: [QuotaTier] = [
            response.fiveHour.map { tier(.fiveHour, $0) },
            response.sevenDay.map { tier(.sevenDay, $0) },
            response.sevenDayOpus.map { tier(.sevenDayOpus, $0) },
            response.sevenDaySonnet.map { tier(.sevenDaySonnet, $0) },
        ].compactMap(\.self)
        return ProviderUsageQuota(provider: .claude, status: .valid, tiers: tiers, fetchedAt: fetchedAt)
    }
```

- [ ] **Step 4: Update the service's references to the renamed type**

In `NemoNotch/Services/UsageQuotaService.swift`, replace every `ClaudeUsageQuota` with `ProviderUsageQuota` and add `provider: .claude` to each constructor call:

- Line 10: `private(set) var quota: ProviderUsageQuota?`
- Line 56: `private func fetch() async -> ProviderUsageQuota {`
- Line 61: `return ProviderUsageQuota(provider: .claude, status: credential.status, fetchedAt: now, errorMessage: credential.message)`
- Line 64: `return ProviderUsageQuota(provider: .claude, status: .expired, fetchedAt: now, errorMessage: credential.message)`
- Line 78: `return ProviderUsageQuota(provider: .claude, status: .expired, fetchedAt: now, errorMessage: "Re-login required")`
- Line 82: `return ProviderUsageQuota(provider: .claude, status: .valid, fetchedAt: now, errorMessage: "HTTP \(status)")`
- Line 89: `return ProviderUsageQuota(provider: .claude, status: .valid, fetchedAt: now, errorMessage: error.localizedDescription)`

(The `parseClaudeCodeQuota` return on line 84 already carries `.claude`.)

- [ ] **Step 5: Run tests + build to verify green**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests 2>&1 | tail -20`
Expected: PASS (14 tests — Step 1 added an assertion, not a new test). The card (`UsageQuotaCardView`) is untouched and still compiles because it reads `service.quota` (no type name) and the `QuotaWindow` cases are unchanged.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Models/UsageQuota.swift NemoNotch/Services/UsageQuotaService.swift NemoNotchTests/UsageQuotaTests.swift
git commit -m "refactor(quota): generalize model to ProviderUsageQuota + accountID"
```

---

### Task 2: Model — Codex parsing, window normalizer, label, backfill (TDD)

**Files:**
- Modify: `NemoNotch/Models/UsageQuota.swift`
- Modify: `NemoNotch/Tabs/UsageQuotaCardView.swift` (one-line: handle the new `.rolling` case so the build stays green)
- Test: `NemoNotchTests/UsageQuotaTests.swift`

- [ ] **Step 1: Write the failing tests**

In `NemoNotchTests/UsageQuotaTests.swift`, add these tests inside the `UsageQuotaTests` struct (before the closing brace):

```swift
    // MARK: - Codex quota parsing

    @Test func parseCodexQuotaFreeTier() throws {
        let json = """
        { "rate_limit": {
            "primary_window": {"used_percent": 7, "limit_window_seconds": 2592000, "reset_at": 1782973688},
            "secondary_window": null
        } }
        """
        let quota = try UsageQuotaParser.parseCodexQuota(data: Data(json.utf8))
        #expect(quota.provider == .codex)
        #expect(quota.tiers.count == 1)
        #expect(quota.tiers[0].window == .rolling(minutes: 43200))
        #expect(quota.tiers[0].utilization == 7)
        #expect(quota.tiers[0].resetsAt != nil)
    }

    @Test func parseCodexQuotaPaidTierOrdersSessionFirst() throws {
        // Windows deliberately out of order: weekly first, session second.
        let json = """
        { "rate_limit": {
            "primary_window":   {"used_percent": 20, "limit_window_seconds": 604800, "reset_at": 1782973688},
            "secondary_window": {"used_percent": 50, "limit_window_seconds": 18000,  "reset_at": 1782900000}
        } }
        """
        let quota = try UsageQuotaParser.parseCodexQuota(data: Data(json.utf8))
        #expect(quota.tiers.map(\.window) == [.rolling(minutes: 300), .rolling(minutes: 10080)])
    }

    @Test func windowLabelFormats() {
        #expect(UsageQuotaFormatter.windowLabel(minutes: 300) == "5h")
        #expect(UsageQuotaFormatter.windowLabel(minutes: 10080) == "7d")
        #expect(UsageQuotaFormatter.windowLabel(minutes: 43200) == "30d")
        #expect(UsageQuotaFormatter.windowLabel(minutes: 1440) == "1d")
        #expect(UsageQuotaFormatter.windowLabel(minutes: 90) == "90m")
    }

    @Test func parseCodexCredentialsValid() throws {
        let json = #"{"auth_mode":"chatgpt","tokens":{"access_token":"tok","account_id":"acct-1"}}"#
        let c = try UsageCredentialParser.parseCodexCredentials(data: Data(json.utf8))
        #expect(c.token == "tok")
        #expect(c.accountID == "acct-1")
        #expect(c.status == .valid)
    }

    @Test func parseCodexCredentialsMissingToken() throws {
        let json = #"{"auth_mode":"chatgpt","tokens":{"account_id":"acct-1"}}"#
        let c = try UsageCredentialParser.parseCodexCredentials(data: Data(json.utf8))
        #expect(c.token == nil)
        #expect(c.status == .parseError)
    }

    @Test func parseCodexCredentialsNotChatGPT() throws {
        let json = #"{"auth_mode":"apikey","tokens":{"access_token":"tok"}}"#
        let c = try UsageCredentialParser.parseCodexCredentials(data: Data(json.utf8))
        #expect(c.status == .notFound)
    }

    @Test func backfillReusesCachedResetWhenMissing() {
        let now = Date(timeIntervalSince1970: 1000)
        let cached = QuotaTier(window: .rolling(minutes: 300), utilization: 10, resetsAt: now.addingTimeInterval(3600))
        let fresh = QuotaTier(window: .rolling(minutes: 300), utilization: 12, resetsAt: nil)
        let filled = fresh.backfillingReset(from: cached, now: now)
        #expect(filled.resetsAt == now.addingTimeInterval(3600))
        #expect(filled.utilization == 12)
    }

    @Test func backfillIgnoresPastCachedReset() {
        let now = Date(timeIntervalSince1970: 1000)
        let cached = QuotaTier(window: .rolling(minutes: 300), utilization: 10, resetsAt: now.addingTimeInterval(-10))
        let fresh = QuotaTier(window: .rolling(minutes: 300), utilization: 12, resetsAt: nil)
        #expect(fresh.backfillingReset(from: cached, now: now).resetsAt == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests 2>&1 | tail -20`
Expected: FAIL to compile — `parseCodexQuota`, `windowLabel`, `parseCodexCredentials`, `backfillingReset`, `.rolling` not defined.

- [ ] **Step 3: Edit the model**

In `NemoNotch/Models/UsageQuota.swift`:

(a) Change `QuotaWindow` to add the `.rolling` case (drop `String`/`CaseIterable`, keep `Hashable`/`Sendable`):

```swift
/// A usage rolling-window. Claude uses named windows (localized labels);
/// Codex uses `.rolling` carrying the window length in minutes.
enum QuotaWindow: Hashable, Sendable {
    case fiveHour
    case sevenDay
    case sevenDayOpus
    case sevenDaySonnet
    case rolling(minutes: Int)
}
```

(b) Add `backfillingReset` as an extension on `QuotaTier` (after the `QuotaTier` struct):

```swift
extension QuotaTier {
    /// Carries a future reset time forward from a cached tier when the fresh
    /// data omits `resetsAt` (some endpoints drop it at 100% utilization).
    /// Borrowed from CodexBar's `RateWindow.backfillingResetTime`.
    func backfillingReset(from cached: QuotaTier?, now: Date = Date()) -> QuotaTier {
        guard resetsAt == nil, let cachedReset = cached?.resetsAt, cachedReset > now else { return self }
        return QuotaTier(window: window, utilization: utilization, resetsAt: cachedReset)
    }
}
```

(c) Add `windowLabel` to `UsageQuotaFormatter` (after `countdown`):

```swift
    /// Short label for a rolling window of `minutes`:
    /// 300→"5h", 10080→"7d", 43200→"30d", else "Nd"/"Nh"/"Nm".
    static func windowLabel(minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }
```

(d) Add the Codex window normalizer (top-level enum, e.g. after `UsageQuotaFormatter`):

```swift
/// Orders Codex rate windows so the short "session" window (300 min) precedes
/// the "weekly" window (10080 min); other lengths keep their relative order at
/// the end. Borrowed from CodexBar's CodexRateWindowNormalizer.
enum CodexRateWindowNormalizer {
    private enum Role { case session, weekly, other }

    private static func role(_ tier: QuotaTier) -> Role {
        guard case let .rolling(minutes) = tier.window else { return .other }
        switch minutes {
        case 300: return .session
        case 10080: return .weekly
        default: return .other
        }
    }

    private static func rank(_ role: Role) -> Int {
        switch role {
        case .session: 0
        case .weekly: 1
        case .other: 2
        }
    }

    static func order(_ tiers: [QuotaTier]) -> [QuotaTier] {
        tiers.enumerated()
            .sorted { lhs, rhs in
                let lr = rank(role(lhs.element)), rr = rank(role(rhs.element))
                return lr != rr ? lr < rr : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
```

(e) Add `parseCodexQuota` to `UsageQuotaParser` (after `parseClaudeCodeQuota`):

```swift
    static func parseCodexQuota(data: Data, fetchedAt: Date = Date()) throws -> ProviderUsageQuota {
        let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
        let windows = [response.rateLimit?.primaryWindow, response.rateLimit?.secondaryWindow].compactMap(\.self)
        let tiers = windows.compactMap { window -> QuotaTier? in
            guard let used = window.usedPercent, let seconds = window.limitWindowSeconds else { return nil }
            return QuotaTier(
                window: .rolling(minutes: seconds / 60),
                utilization: used,
                resetsAt: window.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
        return ProviderUsageQuota(provider: .codex, status: .valid, tiers: CodexRateWindowNormalizer.order(tiers), fetchedAt: fetchedAt)
    }
```

(f) Add `parseCodexCredentials` to `UsageCredentialParser` (after `parseClaudeCredentials`):

```swift
    /// Parses Codex's `~/.codex/auth.json`:
    /// `{ "auth_mode": "chatgpt", "tokens": { "access_token": "...", "account_id": "..." } }`.
    static func parseCodexCredentials(data: Data, now: Date = Date()) throws -> UsageCredential {
        let auth = try JSONDecoder().decode(CodexAuthFile.self, from: data)
        guard auth.authMode == "chatgpt" else {
            return UsageCredential(token: nil, status: .notFound, message: "Codex not using OAuth (auth_mode != chatgpt)")
        }
        guard let token = auth.tokens?.accessToken, !token.isEmpty else {
            return UsageCredential(token: nil, status: .parseError, message: "Codex access_token missing")
        }
        return UsageCredential(token: token, accountID: auth.tokens?.accountID, status: .valid)
    }
```

(g) Add the Codex wire-decoding structs in the `// MARK: - Wire decoding` section (after the Claude ones):

```swift
private struct CodexUsageResponse: Decodable {
    let rateLimit: CodexRateLimit?
    enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
}

private struct CodexRateLimit: Decodable {
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?
    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexWindow: Decodable {
    let usedPercent: Double?
    let resetAt: Int?
    let limitWindowSeconds: Int?
    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }
}

private struct CodexAuthFile: Decodable {
    let authMode: String?
    let tokens: CodexAuthTokens?
    enum CodingKeys: String, CodingKey { case authMode = "auth_mode"; case tokens }
}

private struct CodexAuthTokens: Decodable {
    let accessToken: String?
    let accountID: String?
    enum CodingKeys: String, CodingKey { case accessToken = "access_token"; case accountID = "account_id" }
}
```

- [ ] **Step 4: Keep the card compiling — handle `.rolling` in its label switch**

Adding `.rolling` makes the card's exhaustive `label(for:)` switch fail to compile. In `NemoNotch/Tabs/UsageQuotaCardView.swift`, find:

```swift
    private func label(for window: QuotaWindow) -> LocalizedStringKey {
        switch window {
        case .fiveHour: "quota.window.5h"
        case .sevenDay: "quota.window.7d"
        case .sevenDayOpus: "quota.window.7d_opus"
        case .sevenDaySonnet: "quota.window.7d_sonnet"
        }
    }
```

Add the `.rolling` case:

```swift
    private func label(for window: QuotaWindow) -> LocalizedStringKey {
        switch window {
        case .fiveHour: "quota.window.5h"
        case .sevenDay: "quota.window.7d"
        case .sevenDayOpus: "quota.window.7d_opus"
        case .sevenDaySonnet: "quota.window.7d_sonnet"
        case let .rolling(minutes): LocalizedStringKey(UsageQuotaFormatter.windowLabel(minutes: minutes))
        }
    }
```

(`LocalizedStringKey(<runtime string>)` renders the string verbatim when no catalog key matches — fine for `5h`/`7d`/`30d`. The card is fully rewritten in Task 3; this is just to stay green.)

- [ ] **Step 5: Run tests + build to verify green**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests 2>&1 | tail -20`
Expected: PASS (22 tests).

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Models/UsageQuota.swift NemoNotch/Tabs/UsageQuotaCardView.swift NemoNotchTests/UsageQuotaTests.swift
git commit -m "feat(quota): add Codex parsing, window normalizer, label, reset-backfill"
```

---

### Task 3: Service + Card — multi-provider runtime

These two files change together (the service exposes `quotas`/`hasCodexCredential`; the card consumes them), so they're one task to keep the build green.

**Files:**
- Modify: `NemoNotch/Services/UsageQuotaService.swift`
- Modify: `NemoNotch/Tabs/UsageQuotaCardView.swift`

No unit tests (network + Keychain + SwiftUI; verified by build + manual run per project convention).

- [ ] **Step 1: Rewrite `UsageQuotaService.swift`**

Replace the entire file with:

```swift
import Foundation
import Security

/// Fetches Claude Code and Codex subscription usage and exposes them keyed by
/// provider. Active only while a consuming view is visible (`LifecycleAware`);
/// refreshes throttled to once per 60s with a 5-minute auto-refresh timer.
@MainActor
@Observable
final class UsageQuotaService: LifecycleAware {
    private(set) var quotas: [QuotaProvider: ProviderUsageQuota] = [:]
    private(set) var isRefreshing = false
    /// Whether a Codex credential exists (drives the Codex section's visibility).
    /// Computed at init so the UI gate is correct before the first fetch.
    private(set) var hasCodexCredential = false

    private let claudeKeychainService = "Claude Code-credentials"
    private let claudeCredentialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")
    private let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let codexKeychainService = "Codex Auth"
    private let codexAuthURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")
    private let codexUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let throttleInterval: TimeInterval = 60
    private let refreshInterval: TimeInterval = 300

    private var timer: Timer?
    private var lastFetched: Date?

    init() {
        LogService.info("UsageQuotaService init", category: "UsageQuotaService")
        hasCodexCredential = codexCredentialPresent()
    }

    deinit { MainActor.assumeIsolated { timer?.invalidate() } }

    func setActive(_ active: Bool) {
        if active {
            LogService.debug("UsageQuotaService active", category: "UsageQuotaService")
            Task { await refresh(force: false) }
            guard timer == nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refresh(force: false) }
            }
        } else {
            LogService.debug("UsageQuotaService inactive", category: "UsageQuotaService")
            timer?.invalidate()
            timer = nil
        }
    }

    func refresh(force: Bool) async {
        if !force, let last = lastFetched, Date().timeIntervalSince(last) < throttleInterval {
            LogService.debug("Quota refresh throttled", category: "UsageQuotaService")
            return
        }
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }

        hasCodexCredential = codexCredentialPresent()
        async let claudeTask = fetchClaude()
        async let codexTask = fetchCodexIfPresent()
        let (claudeResult, codexResult) = await (claudeTask, codexTask)

        var next: [QuotaProvider: ProviderUsageQuota] = [:]
        next[.claude] = backfilled(claudeResult, from: quotas[.claude])
        if let codexResult { next[.codex] = backfilled(codexResult, from: quotas[.codex]) }
        quotas = next
        lastFetched = Date()
    }

    /// Re-applies a future reset time from the previous fetch to any fresh tier
    /// that came back without one.
    private func backfilled(_ quota: ProviderUsageQuota, from previous: ProviderUsageQuota?, now: Date = Date()) -> ProviderUsageQuota {
        guard !quota.tiers.isEmpty, let previous else { return quota }
        let tiers = quota.tiers.map { tier in
            tier.backfillingReset(from: previous.tiers.first { $0.window == tier.window }, now: now)
        }
        return ProviderUsageQuota(provider: quota.provider, status: quota.status, tiers: tiers, fetchedAt: quota.fetchedAt, errorMessage: quota.errorMessage)
    }

    // MARK: - Claude

    private func fetchClaude() async -> ProviderUsageQuota {
        let now = Date()
        let credential = readClaudeCredential(now: now)
        guard let token = credential.token else {
            LogService.warn("Claude quota: no credential (status \(credential.status))", category: "UsageQuotaService")
            return ProviderUsageQuota(provider: .claude, status: credential.status, fetchedAt: now, errorMessage: credential.message)
        }
        if credential.status == .expired {
            return ProviderUsageQuota(provider: .claude, status: .expired, fetchedAt: now, errorMessage: credential.message)
        }

        var request = URLRequest(url: claudeUsageURL, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                LogService.warn("Claude quota: HTTP 401", category: "UsageQuotaService")
                return ProviderUsageQuota(provider: .claude, status: .expired, fetchedAt: now, errorMessage: "Re-login required")
            }
            guard (200 ..< 300).contains(status) else {
                LogService.error("Claude quota: HTTP \(status)", category: "UsageQuotaService")
                return ProviderUsageQuota(provider: .claude, status: .valid, fetchedAt: now, errorMessage: "HTTP \(status)")
            }
            let parsed = try UsageQuotaParser.parseClaudeCodeQuota(data: data, fetchedAt: now)
            LogService.info("Claude quota fetched: \(parsed.tiers.count) tiers", category: "UsageQuotaService")
            return parsed
        } catch {
            LogService.error("Claude quota fetch failed: \(error.localizedDescription)", category: "UsageQuotaService")
            return ProviderUsageQuota(provider: .claude, status: .valid, fetchedAt: now, errorMessage: error.localizedDescription)
        }
    }

    private func readClaudeCredential(now: Date) -> UsageCredential {
        if let data = keychainBlob(service: claudeKeychainService),
           let credential = try? UsageCredentialParser.parseClaudeCredentials(data: data, now: now) {
            return credential
        }
        guard FileManager.default.fileExists(atPath: claudeCredentialsURL.path) else {
            return UsageCredential(token: nil, status: .notFound)
        }
        do {
            let data = try Data(contentsOf: claudeCredentialsURL)
            return try UsageCredentialParser.parseClaudeCredentials(data: data, now: now)
        } catch {
            return UsageCredential(token: nil, status: .parseError, message: error.localizedDescription)
        }
    }

    // MARK: - Codex

    private func fetchCodexIfPresent() async -> ProviderUsageQuota? {
        guard hasCodexCredential else { return nil }
        return await fetchCodex()
    }

    private func fetchCodex() async -> ProviderUsageQuota {
        let now = Date()
        let credential = readCodexCredential()
        guard let token = credential.token else {
            LogService.warn("Codex quota: no credential (status \(credential.status))", category: "UsageQuotaService")
            return ProviderUsageQuota(provider: .codex, status: credential.status, fetchedAt: now, errorMessage: credential.message)
        }

        var request = URLRequest(url: codexUsageURL, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("NemoNotch", forHTTPHeaderField: "User-Agent")
        if let accountID = credential.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                LogService.warn("Codex quota: HTTP 401", category: "UsageQuotaService")
                return ProviderUsageQuota(provider: .codex, status: .expired, fetchedAt: now, errorMessage: "Re-login required")
            }
            guard (200 ..< 300).contains(status) else {
                LogService.error("Codex quota: HTTP \(status)", category: "UsageQuotaService")
                return ProviderUsageQuota(provider: .codex, status: .valid, fetchedAt: now, errorMessage: "HTTP \(status)")
            }
            let parsed = try UsageQuotaParser.parseCodexQuota(data: data, fetchedAt: now)
            LogService.info("Codex quota fetched: \(parsed.tiers.count) tiers", category: "UsageQuotaService")
            return parsed
        } catch {
            LogService.error("Codex quota fetch failed: \(error.localizedDescription)", category: "UsageQuotaService")
            return ProviderUsageQuota(provider: .codex, status: .valid, fetchedAt: now, errorMessage: error.localizedDescription)
        }
    }

    private func readCodexCredential() -> UsageCredential {
        if let data = keychainBlob(service: codexKeychainService),
           let credential = try? UsageCredentialParser.parseCodexCredentials(data: data) {
            return credential
        }
        guard FileManager.default.fileExists(atPath: codexAuthURL.path) else {
            return UsageCredential(token: nil, status: .notFound)
        }
        do {
            let data = try Data(contentsOf: codexAuthURL)
            return try UsageCredentialParser.parseCodexCredentials(data: data)
        } catch {
            return UsageCredential(token: nil, status: .parseError, message: error.localizedDescription)
        }
    }

    private func codexCredentialPresent() -> Bool {
        if FileManager.default.fileExists(atPath: codexAuthURL.path) { return true }
        return keychainBlob(service: codexKeychainService) != nil
    }

    // MARK: - Keychain

    /// Reads a CLI's credential blob, stored as a Keychain generic-password
    /// item keyed by service name (the account is the macOS username and
    /// varies), so we match on `kSecAttrService` alone and take one result.
    private func keychainBlob(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
```

- [ ] **Step 2: Rewrite `UsageQuotaCardView.swift`**

Replace the entire file with:

```swift
import SwiftUI

/// Compact card showing Claude Code and/or Codex usage quotas. Each present
/// provider gets a labeled section. Binds the quota service to its visibility
/// via `.activates`.
struct UsageQuotaCardView: View {
    @Environment(UsageQuotaService.self) private var service
    @Environment(AppSettings.self) private var appSettings

    /// Providers to show: Claude when enabled, Codex when a credential exists.
    private var visibleProviders: [QuotaProvider] {
        var result: [QuotaProvider] = []
        if appSettings.claudeEnabled { result.append(.claude) }
        if service.hasCodexCredential { result.append(.codex) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(visibleProviders, id: \.self) { provider in
                providerSection(provider)
            }
        }
        .padding(10)
        .notchCard(radius: 10, fill: NotchTheme.surface)
        .activates(service)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("quota.title")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(NotchTheme.textPrimary)
            Spacer()
            Button {
                Task { await service.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(NotchTheme.textSecondary)
                    .rotationEffect(service.isRefreshing ? .degrees(360) : .degrees(0))
                    .animation(
                        service.isRefreshing
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : nil, // stop instantly — no reverse sweep back to 0°
                        value: service.isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(service.isRefreshing)
            .help("quota.refresh")
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: QuotaProvider) -> some View {
        let quota = service.quotas[provider]
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: provider.displayName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(NotchTheme.textSecondary)

            if let quota, quota.status == .valid, !quota.tiers.isEmpty {
                ForEach(quota.tiers, id: \.window) { tier in
                    tierRow(tier)
                }
            } else {
                Text(statusKey(for: quota))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(NotchTheme.textTertiary)
            }
        }
    }

    private func tierRow(_ tier: QuotaTier) -> some View {
        HStack(spacing: 6) {
            label(for: tier.window)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NotchTheme.textSecondary)
                .frame(width: 64, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(color(for: tier.utilization))
                        .frame(width: geo.size.width * min(max(tier.utilization, 0), 100) / 100)
                        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: tier.utilization)
                }
            }
            .frame(height: 5)

            Text(verbatim: "\(Int(tier.utilization.rounded()))%")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(color(for: tier.utilization))
                .frame(width: 34, alignment: .trailing)

            countdownText(tier.resetsAt)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(NotchTheme.textTertiary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func countdownText(_ date: Date?) -> Text {
        guard let date else { return Text(verbatim: "--") }
        switch UsageQuotaFormatter.countdown(until: date) {
        case .reset: return Text("quota.reset")
        case let .text(value): return Text(verbatim: value)
        }
    }

    private func label(for window: QuotaWindow) -> Text {
        switch window {
        case .fiveHour: Text("quota.window.5h")
        case .sevenDay: Text("quota.window.7d")
        case .sevenDayOpus: Text("quota.window.7d_opus")
        case .sevenDaySonnet: Text("quota.window.7d_sonnet")
        case let .rolling(minutes): Text(verbatim: UsageQuotaFormatter.windowLabel(minutes: minutes))
        }
    }

    private func color(for utilization: Double) -> Color {
        if utilization >= 90 { return .red }
        if utilization >= 70 { return .orange }
        return .green
    }

    private func statusKey(for quota: ProviderUsageQuota?) -> LocalizedStringKey {
        guard let quota else { return "quota.status.reading" }
        switch quota.status {
        case .valid: return "quota.status.no_data"
        case .expired: return "quota.status.login_required"
        case .notFound: return "quota.status.not_logged_in"
        case .parseError: return "quota.status.error"
        }
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -quiet 2>&1 | tail -8`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Services/UsageQuotaService.swift NemoNotch/Tabs/UsageQuotaCardView.swift
git commit -m "feat(quota): multi-provider service (Claude+Codex) + card sections"
```

---

### Task 4: Wire Codex visibility into AIChatTab gate

**Files:**
- Modify: `NemoNotch/Tabs/AIChatTab.swift`

- [ ] **Step 1: Add the service to AIChatTab's environment**

In `NemoNotch/Tabs/AIChatTab.swift`, find the existing environment declarations near the top of `struct AIChatTab`:

```swift
    @Environment(AICLIMonitorService.self) var aiService
    @Environment(AppSettings.self) var appSettings
```

Add below them:

```swift
    @Environment(UsageQuotaService.self) private var quotaService
```

- [ ] **Step 2: Update the card gate in `sessionList`**

Find (added by the Claude-only feature):

```swift
            if appSettings.claudeEnabled {
                UsageQuotaCardView()
            }
```

Replace with:

```swift
            if appSettings.claudeEnabled || quotaService.hasCodexCredential {
                UsageQuotaCardView()
            }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -quiet 2>&1 | tail -8`
Expected: BUILD SUCCEEDED. (`UsageQuotaService` is already injected into the NotchView environment chain by the Claude-only feature — no AppDelegate change needed.)

- [ ] **Step 4: Commit**

```bash
git add NemoNotch/Tabs/AIChatTab.swift
git commit -m "feat(quota): show card when Codex credential present"
```

---

### Task 5: Documentation

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `README_CN.md`

- [ ] **Step 1: Update `CLAUDE.md`**

(a) In the Services mermaid block, change the `UQS` node line:

```
        UQS["UsageQuotaService<br/>Claude oauth/usage 5h/7d quota"]
```

to:

```
        UQS["UsageQuotaService<br/>Claude + Codex usage quota"]
```

(b) Find the **Usage quota** prose paragraph (under "AI Service Architecture") and replace it with:

```markdown
**Usage quota:** `UsageQuotaService` exposes `quotas: [QuotaProvider: ProviderUsageQuota]` and fetches **Claude Code** (Keychain `Claude Code-credentials` / `~/.claude/.credentials.json` → `GET /api/oauth/usage`) and **Codex** (`~/.codex/auth.json` / Keychain `Codex Auth` → `GET chatgpt.com/backend-api/wham/usage` with `ChatGPT-Account-Id`) concurrently. The Codex section appears only when a Codex credential is detected (`hasCodexCredential`). Windows are normalized (session→weekly) and rendered as a card in `AIChatTab`. `LifecycleAware`, 60s refresh throttle, 5-minute timer, robust `resets_at` parse, and reset-backfill from the previous fetch (ideas borrowed from `CodexBar`). Gemini quota is a planned follow-up (needs OAuth token refresh + project resolution).
```

- [ ] **Step 2: Update `README.md`**

Find the Claude usage-quota bullet added by the prior feature (search for "usage quota" / "5-hour") and replace it with:

```markdown
- **AI usage quota** — shows your Claude Code and Codex usage quotas (utilization % + reset countdown) as a card in the AI tab, read from each CLI's OAuth credential. The Codex section appears automatically when the Codex CLI is signed in.
```

- [ ] **Step 3: Update `README_CN.md`**

Find the corresponding Chinese bullet and replace it with:

```markdown
- **AI 用量配额** —— 在 AI 标签页以卡片展示 Claude Code 与 Codex 的用量配额(使用率 % + 重置倒计时),数据来自各 CLI 的 OAuth 凭证。检测到 Codex CLI 已登录时自动显示 Codex 段。
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md README_CN.md
git commit -m "docs(quota): document Codex multi-provider quota"
```

---

## Final verification

- [ ] Full suite: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' 2>&1 | tail -5` — `** TEST SUCCEEDED **`.
- [ ] Manual: open notch → AI tab. With Claude enabled and Codex signed in (this machine has both), the card shows a **Claude Code** section (5h/7d) and a **Codex** section (its window, e.g. `30d` on free / `5h`+`7d` on paid) with bars, percentages, and countdowns. Refresh spins clockwise and stops cleanly.
- [ ] Merge `feature/multi-provider-quota` → `develop`.

## Self-review notes (addressed)

- **Spec coverage:** `QuotaProvider`+displayName (T1), `.rolling`/windowLabel/normalizer/backfill (T2), `parseCodexQuota`/`parseCodexCredentials`/`accountID` (T1+T2), service `quotas`+`hasCodexCredential`+concurrent fetch+backfill (T3), card sections + AppSettings gate (T3), AIChatTab gate (T4), docs (T5), no-localization-change + no-AppDelegate-change (honored). All present.
- **Build-green per task:** T1 renames type in model+service together; T2 adds `.rolling` and patches the card switch so it compiles; T3 swaps `quota`→`quotas` in service and card in the same task. No task leaves a dangling reference.
- **Type consistency:** `ProviderUsageQuota(provider:status:tiers:fetchedAt:errorMessage:)`, `QuotaWindow.rolling(minutes:)`, `UsageQuotaFormatter.windowLabel(minutes:)`, `CodexRateWindowNormalizer.order(_:)`, `QuotaTier.backfillingReset(from:now:)`, `service.quotas` / `service.hasCodexCredential` used identically across tasks.
- **No placeholders:** every code/command step is concrete.
