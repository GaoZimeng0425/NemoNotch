# Claude Code Usage Quota Card — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Claude Code's 5-hour and 7-day usage quotas (utilization % + reset countdown) as a compact card in `AIChatTab`.

**Architecture:** Pure parse/format logic in `Models/UsageQuota.swift` (unit-tested); networking + Keychain + lifecycle in `Services/UsageQuotaService.swift` (`@Observable`/`LifecycleAware`); SwiftUI card in `Tabs/UsageQuotaCardView.swift`; wired into `AIChatTab`'s session list and injected from `AppDelegate`.

**Tech Stack:** Swift 6, SwiftUI, `@Observable`, `Security` (Keychain), `URLSession`, Swift Testing, String Catalog (`Localizable.xcstrings`).

**Design spec:** `docs/plans/2026-06-09-claude-usage-quota-design.md`

**Working branch:** `feature/claude-usage-quota` (already checked out).

**Conventions used throughout:**
- Build check: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -quiet`
- Test run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests`
- Xcode 16 auto-syncs source files from disk (per CLAUDE.md / memory `project_xcode-file-sync`) — **do NOT edit `project.pbxproj` to register new files.** Just create them under `NemoNotch/` or `NemoNotchTests/`.

---

### Task 1: Pure models, parsers, and formatter (TDD)

**Files:**
- Create: `NemoNotch/Models/UsageQuota.swift`
- Test: `NemoNotchTests/UsageQuotaTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `NemoNotchTests/UsageQuotaTests.swift`:

```swift
import Foundation
@testable import NemoNotch
import Testing

struct UsageQuotaTests {
    // MARK: - Credential parsing

    @Test func parseCredentialValid() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":1780988250441}}"#
        let now = Date(timeIntervalSince1970: 1_700_000_000) // before expiry
        let cred = try UsageCredentialParser.parseClaudeCredentials(data: Data(json.utf8), now: now)
        #expect(cred.token == "tok-abc")
        #expect(cred.status == .valid)
    }

    @Test func parseCredentialExpired() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"tok-abc","expiresAt":1700000000000}}"#
        let now = Date(timeIntervalSince1970: 1_800_000_000) // after expiry
        let cred = try UsageCredentialParser.parseClaudeCredentials(data: Data(json.utf8), now: now)
        #expect(cred.token == "tok-abc")
        #expect(cred.status == .expired)
    }

    @Test func parseCredentialMissingToken() throws {
        let json = #"{"claudeAiOauth":{"expiresAt":1780988250441}}"#
        let cred = try UsageCredentialParser.parseClaudeCredentials(data: Data(json.utf8), now: Date())
        #expect(cred.token == nil)
        #expect(cred.status == .parseError)
    }

    // MARK: - Quota parsing (real payload shape, incl. microsecond resets_at)

    @Test func parseQuotaRealPayload() throws {
        let json = """
        {
          "five_hour": {"utilization": 6.0, "resets_at": "2026-06-09T08:00:00.858062+00:00"},
          "seven_day": {"utilization": 3.0, "resets_at": "2026-06-15T13:00:00.858087+00:00"},
          "seven_day_opus": null,
          "seven_day_sonnet": {"utilization": 0.0, "resets_at": "2026-06-15T13:00:00.858099+00:00"},
          "extra_usage": {"is_enabled": false}
        }
        """
        let quota = try UsageQuotaParser.parseClaudeCodeQuota(data: Data(json.utf8))
        #expect(quota.status == .valid)
        // null tiers dropped → 3 tiers, in declared order
        #expect(quota.tiers.map(\.window) == [.fiveHour, .sevenDay, .sevenDaySonnet])
        #expect(quota.tiers[0].utilization == 6.0)
        // regression: microsecond + offset resets_at MUST parse to a non-nil Date
        #expect(quota.tiers[0].resetsAt != nil)
    }

    @Test func parseQuotaMalformedThrows() {
        #expect(throws: (any Error).self) {
            try UsageQuotaParser.parseClaudeCodeQuota(data: Data("not json".utf8))
        }
    }

    @Test func parseResetDateMicroseconds() {
        let d = UsageQuotaParser.parseResetDate("2026-06-09T08:00:00.858062+00:00")
        #expect(d != nil)
    }

    // MARK: - Countdown formatting

    @Test func countdownDaysAndHours() {
        let now = Date(timeIntervalSince1970: 0)
        let target = now.addingTimeInterval(6 * 86_400 + 3 * 3_600)
        #expect(UsageQuotaFormatter.countdown(until: target, now: now) == .text("6d3h"))
    }

    @Test func countdownHoursAndMinutes() {
        let now = Date(timeIntervalSince1970: 0)
        let target = now.addingTimeInterval(4 * 3_600 + 12 * 60)
        #expect(UsageQuotaFormatter.countdown(until: target, now: now) == .text("4h12m"))
    }

    @Test func countdownMinutesOnly() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(UsageQuotaFormatter.countdown(until: now.addingTimeInterval(300), now: now) == .text("5m"))
    }

    @Test func countdownUnderOneMinute() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(UsageQuotaFormatter.countdown(until: now.addingTimeInterval(30), now: now) == .text("<1m"))
    }

    @Test func countdownAlreadyReset() {
        let now = Date(timeIntervalSince1970: 100)
        #expect(UsageQuotaFormatter.countdown(until: now.addingTimeInterval(-10), now: now) == .reset)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests`
Expected: FAIL to compile — `UsageCredentialParser`, `UsageQuotaParser`, `UsageQuotaFormatter`, etc. not defined.

- [ ] **Step 3: Write the implementation**

Create `NemoNotch/Models/UsageQuota.swift`:

```swift
import Foundation

/// Status of the Claude OAuth credential / quota fetch.
enum CredentialStatus: Equatable, Sendable {
    case valid
    case expired
    case notFound
    case parseError
}

/// One Claude usage rolling-window.
enum QuotaWindow: String, Sendable, CaseIterable {
    case fiveHour
    case sevenDay
    case sevenDayOpus
    case sevenDaySonnet
}

/// A single quota tier: utilization (0...100) + when it resets.
struct QuotaTier: Equatable, Sendable {
    let window: QuotaWindow
    let utilization: Double
    let resetsAt: Date?
}

/// Parsed Claude Code usage quota (or an error state).
struct ClaudeUsageQuota: Equatable, Sendable {
    let status: CredentialStatus
    let tiers: [QuotaTier]
    let fetchedAt: Date
    let errorMessage: String?

    init(status: CredentialStatus, tiers: [QuotaTier] = [], fetchedAt: Date = Date(), errorMessage: String? = nil) {
        self.status = status
        self.tiers = tiers
        self.fetchedAt = fetchedAt
        self.errorMessage = errorMessage
    }
}

/// OAuth credential extracted from Keychain / credentials file.
struct UsageCredential: Equatable, Sendable {
    let token: String?
    let status: CredentialStatus
    let message: String?

    init(token: String?, status: CredentialStatus, message: String? = nil) {
        self.token = token
        self.status = status
        self.message = message
    }
}

enum UsageCredentialParser {
    /// Parses `~/.claude/.credentials.json` or the Keychain blob.
    /// Shape: `{ "claudeAiOauth": { "accessToken": "...", "expiresAt": <ms epoch> } }`.
    static func parseClaudeCredentials(data: Data, now: Date = Date()) throws -> UsageCredential {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            return UsageCredential(token: nil, status: .parseError, message: "Claude credentials JSON is not an object")
        }
        guard let entry = (root["claudeAiOauth"] ?? root["claude.ai_oauth"]) as? [String: Any] else {
            return UsageCredential(token: nil, status: .parseError, message: "No OAuth entry in Claude credentials")
        }
        guard let token = entry["accessToken"] as? String, !token.isEmpty else {
            return UsageCredential(token: nil, status: .parseError, message: "accessToken is empty or missing")
        }
        if let expiresAt = entry["expiresAt"], isExpired(expiresAt, now: now) {
            return UsageCredential(token: token, status: .expired, message: "OAuth token has expired")
        }
        return UsageCredential(token: token, status: .valid)
    }

    private static func isExpired(_ value: Any, now: Date) -> Bool {
        let raw: Double
        if let d = value as? Double { raw = d }
        else if let i = value as? Int { raw = Double(i) }
        else { return false }
        // Claude stores milliseconds (13 digits); normalize to seconds.
        let seconds = raw > 1_000_000_000_000 ? raw / 1_000 : raw
        return Date(timeIntervalSince1970: seconds) < now
    }
}

enum UsageQuotaParser {
    static func parseClaudeCodeQuota(data: Data, fetchedAt: Date = Date()) throws -> ClaudeUsageQuota {
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        let tiers: [QuotaTier] = [
            response.fiveHour.map { tier(.fiveHour, $0) },
            response.sevenDay.map { tier(.sevenDay, $0) },
            response.sevenDayOpus.map { tier(.sevenDayOpus, $0) },
            response.sevenDaySonnet.map { tier(.sevenDaySonnet, $0) },
        ].compactMap { $0 }
        return ClaudeUsageQuota(status: .valid, tiers: tiers, fetchedAt: fetchedAt)
    }

    /// Robust ISO8601 parse. The live API returns 6-digit fractional seconds
    /// plus a `+00:00` offset (e.g. `2026-06-09T08:00:00.858062+00:00`).
    /// `ISO8601DateFormatter` with `.withFractionalSeconds` only accepts 3
    /// fractional digits, so we truncate to milliseconds before parsing.
    static func parseResetDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        if let truncated = truncateFractionalSeconds(value), let date = fractional.date(from: truncated) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    private static func tier(_ window: QuotaWindow, _ source: ClaudeUsageTier) -> QuotaTier {
        QuotaTier(window: window, utilization: source.utilization, resetsAt: source.resetsAt.flatMap(parseResetDate))
    }

    /// Trims fractional seconds to 3 digits: `...00.858062+00:00` → `...00.858+00:00`.
    private static func truncateFractionalSeconds(_ value: String) -> String? {
        guard let dot = value.firstIndex(of: ".") else { return nil }
        let afterDot = value.index(after: dot)
        var end = afterDot
        while end < value.endIndex, value[end].isNumber { end = value.index(after: end) }
        let digitCount = value.distance(from: afterDot, to: end)
        guard digitCount > 3 else { return nil }
        let keepEnd = value.index(afterDot, offsetBy: 3)
        return String(value[..<keepEnd]) + String(value[end...])
    }
}

enum UsageQuotaFormatter {
    enum CountdownResult: Equatable {
        case text(String)
        case reset
    }

    /// Formats time until `target` as `6d3h` / `4h12m` / `5m` / `<1m`, or `.reset` once past.
    static func countdown(until target: Date, now: Date = Date()) -> CountdownResult {
        let seconds = Int(target.timeIntervalSince(now))
        guard seconds > 0 else { return .reset }
        guard seconds >= 60 else { return .text("<1m") }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 {
            return .text(hours > 0 ? "\(days)d\(hours)h" : "\(days)d")
        }
        if hours > 0 {
            return .text(minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h")
        }
        return .text("\(minutes)m")
    }
}

// MARK: - Wire decoding

private struct ClaudeUsageResponse: Decodable {
    let fiveHour: ClaudeUsageTier?
    let sevenDay: ClaudeUsageTier?
    let sevenDayOpus: ClaudeUsageTier?
    let sevenDaySonnet: ClaudeUsageTier?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
    }
}

private struct ClaudeUsageTier: Decodable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Models/UsageQuota.swift NemoNotchTests/UsageQuotaTests.swift
git commit -m "feat(quota): add Claude usage quota models, parsers, formatter"
```

---

### Task 2: UsageQuotaService (Keychain + networking + lifecycle)

**Files:**
- Create: `NemoNotch/Services/UsageQuotaService.swift`

No unit test: this layer is network + Keychain I/O, which per CLAUDE.md testing guidance is verified by build + manual run, not unit tests. All pure logic it calls is already covered by Task 1.

- [ ] **Step 1: Write the implementation**

Create `NemoNotch/Services/UsageQuotaService.swift`:

```swift
import Foundation
import Security

/// Fetches Claude Code subscription usage from the OAuth usage endpoint and
/// exposes it to the UI. Active only while a consuming view is visible
/// (`LifecycleAware`); refreshes are throttled to at most once per 60s.
@MainActor
@Observable
final class UsageQuotaService: LifecycleAware {
    private(set) var quota: ClaudeUsageQuota?
    private(set) var isRefreshing = false

    private let keychainService = "Claude Code-credentials"
    private let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")
    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let throttleInterval: TimeInterval = 60
    private let refreshInterval: TimeInterval = 300

    private var timer: Timer?
    private var lastFetched: Date?

    init() {
        LogService.info("UsageQuotaService init", category: "UsageQuotaService")
    }

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
        quota = await fetch()
        lastFetched = Date()
    }

    private func fetch() async -> ClaudeUsageQuota {
        let now = Date()
        let credential = readCredential(now: now)
        guard let token = credential.token else {
            LogService.warn("Quota: no credential (status \(credential.status))", category: "UsageQuotaService")
            return ClaudeUsageQuota(status: credential.status, fetchedAt: now, errorMessage: credential.message)
        }
        if credential.status == .expired {
            return ClaudeUsageQuota(status: .expired, fetchedAt: now, errorMessage: credential.message)
        }

        var request = URLRequest(url: usageURL, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                LogService.warn("Quota: HTTP 401 unauthorized", category: "UsageQuotaService")
                return ClaudeUsageQuota(status: .expired, fetchedAt: now, errorMessage: "Re-login required")
            }
            guard (200..<300).contains(status) else {
                LogService.error("Quota: HTTP \(status)", category: "UsageQuotaService")
                return ClaudeUsageQuota(status: .valid, fetchedAt: now, errorMessage: "HTTP \(status)")
            }
            let parsed = try UsageQuotaParser.parseClaudeCodeQuota(data: data, fetchedAt: now)
            LogService.info("Quota fetched: \(parsed.tiers.count) tiers", category: "UsageQuotaService")
            return parsed
        } catch {
            LogService.error("Quota fetch failed: \(error.localizedDescription)", category: "UsageQuotaService")
            return ClaudeUsageQuota(status: .valid, fetchedAt: now, errorMessage: error.localizedDescription)
        }
    }

    private func readCredential(now: Date) -> UsageCredential {
        if let data = keychainBlob(),
           let credential = try? UsageCredentialParser.parseClaudeCredentials(data: data, now: now) {
            return credential
        }
        guard FileManager.default.fileExists(atPath: credentialsURL.path) else {
            return UsageCredential(token: nil, status: .notFound)
        }
        do {
            let data = try Data(contentsOf: credentialsURL)
            return try UsageCredentialParser.parseClaudeCredentials(data: data, now: now)
        } catch {
            return UsageCredential(token: nil, status: .parseError, message: error.localizedDescription)
        }
    }

    /// Reads the generic-password blob keyed on service name only (the account
    /// is the macOS username and may vary). Mirrors the Keychain read pattern
    /// in `OpenClawService` (see docs/macos-cookbook.md §14).
    private func keychainBlob() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Services/UsageQuotaService.swift
git commit -m "feat(quota): add UsageQuotaService (keychain + oauth/usage fetch)"
```

---

### Task 3: UsageQuotaCardView

**Files:**
- Create: `NemoNotch/Tabs/UsageQuotaCardView.swift`

- [ ] **Step 1: Write the view**

Create `NemoNotch/Tabs/UsageQuotaCardView.swift`:

```swift
import SwiftUI

/// Compact card showing Claude Code 5h / 7d usage quotas. Binds the quota
/// service to its own visibility via `.activates`.
struct UsageQuotaCardView: View {
    @Environment(UsageQuotaService.self) private var service

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
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
                            : .default,
                        value: service.isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(service.isRefreshing)
            .help("quota.refresh")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let quota = service.quota, quota.status == .valid, !quota.tiers.isEmpty {
            ForEach(quota.tiers, id: \.window) { tier in
                tierRow(tier)
            }
        } else {
            Text(statusKey)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NotchTheme.textTertiary)
        }
    }

    private func tierRow(_ tier: QuotaTier) -> some View {
        HStack(spacing: 6) {
            Text(label(for: tier.window))
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
        case .text(let value): return Text(verbatim: value)
        }
    }

    private func label(for window: QuotaWindow) -> LocalizedStringKey {
        switch window {
        case .fiveHour: "quota.window.5h"
        case .sevenDay: "quota.window.7d"
        case .sevenDayOpus: "quota.window.7d_opus"
        case .sevenDaySonnet: "quota.window.7d_sonnet"
        }
    }

    private func color(for utilization: Double) -> Color {
        if utilization >= 90 { return .red }
        if utilization >= 70 { return .orange }
        return .green
    }

    private var statusKey: LocalizedStringKey {
        guard let quota = service.quota else {
            return "quota.status.reading"
        }
        switch quota.status {
        case .valid: return "quota.status.no_data"
        case .expired: return "quota.status.login_required"
        case .notFound: return "quota.status.not_logged_in"
        case .parseError: return "quota.status.error"
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED. (Localized keys will render as raw keys until Task 5 — that is fine for a build.)

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Tabs/UsageQuotaCardView.swift
git commit -m "feat(quota): add UsageQuotaCardView"
```

---

### Task 4: Wire the service and card into the app

**Files:**
- Modify: `NemoNotch/NemoNotchApp.swift` (service property, construction, environment injection)
- Modify: `NemoNotch/Tabs/AIChatTab.swift` (render the card in the session list)

- [ ] **Step 1: Add the service property in `AppDelegate`**

In `NemoNotch/NemoNotchApp.swift`, find the property block ending with:

```swift
    private(set) var notificationPermissionMonitor: NotificationPermissionMonitor?
    private(set) var quickStartController: QuickStartWindowController?
```

Add after `notificationPermissionMonitor`:

```swift
    private(set) var usageQuotaService: UsageQuotaService?
```

- [ ] **Step 2: Construct the service**

In the same file, find:

```swift
        let weather = WeatherService()
        if !UITestMode.isActive, !settings.weatherCity.isEmpty {
            weather.updateCity(settings.weatherCity)
        }
        weatherService = weather
```

Add immediately after that block:

```swift
        let usageQuota = UsageQuotaService()
        usageQuotaService = usageQuota
```

- [ ] **Step 3: Inject into the NotchView environment chain**

Find the `NotchView` environment chain and add `.environment(usageQuota)` after `.environment(aiMonitor)`:

```swift
                NotchView(screen: screen)
                    .environment(coordinator)
                    .environment(settings)
                    .environment(media)
                    .environment(permissionMonitor)
                    .environment(calendar)
                    .environment(aiMonitor)
                    .environment(usageQuota)
                    .environment(openClaw)
```

- [ ] **Step 4: Render the card in `AIChatTab`'s session list**

In `NemoNotch/Tabs/AIChatTab.swift`, find `sessionList`:

```swift
    private var sessionList: some View {
        VStack(spacing: 12) {
            aiConsoleHeader

            ScrollView {
```

Change the top of the `VStack` to insert the card after the header:

```swift
    private var sessionList: some View {
        VStack(spacing: 12) {
            aiConsoleHeader

            if appSettings.claudeEnabled {
                UsageQuotaCardView()
            }

            ScrollView {
```

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/NemoNotchApp.swift NemoNotch/Tabs/AIChatTab.swift
git commit -m "feat(quota): wire UsageQuotaService + card into AIChatTab"
```

---

### Task 5: Localization keys

**Files:**
- Modify: `NemoNotch/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the quota.* keys (en + zh-Hans)**

Run this script from the repo root (it adds keys idempotently, preserving formatting):

```bash
python3 - <<'PY'
import json
path = "NemoNotch/Resources/Localizable.xcstrings"
with open(path) as f:
    cat = json.load(f)

entries = {
    "quota.title":                 ("Usage",            "用量"),
    "quota.refresh":               ("Refresh",          "刷新"),
    "quota.window.5h":             ("5h",               "5小时"),
    "quota.window.7d":             ("7d",               "7天"),
    "quota.window.7d_opus":        ("7d Opus",          "7天 Opus"),
    "quota.window.7d_sonnet":      ("7d Sonnet",        "7天 Sonnet"),
    "quota.reset":                 ("Reset",            "已重置"),
    "quota.status.reading":        ("Reading…",         "读取中…"),
    "quota.status.no_data":        ("No data",          "无数据"),
    "quota.status.not_logged_in":  ("Not logged in",    "未登录"),
    "quota.status.login_required": ("Re-login required","需重新登录"),
    "quota.status.error":          ("Error",            "错误"),
}

for key, (en, zh) in entries.items():
    cat["strings"][key] = {
        "localizations": {
            "en":      {"stringUnit": {"state": "translated", "value": en}},
            "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
        }
    }

with open(path, "w") as f:
    json.dump(cat, f, ensure_ascii=False, indent=2)
    f.write("\n")
print("added", len(entries), "keys; total now", len(cat["strings"]))
PY
```

Expected output: `added 12 keys; total now 249`.

- [ ] **Step 2: Build to verify the catalog is valid and keys resolve**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add NemoNotch/Resources/Localizable.xcstrings
git commit -m "feat(quota): add quota.* localization keys (en + zh-Hans)"
```

---

### Task 6: Documentation

**Files:**
- Modify: `CLAUDE.md` (service list in the architecture mermaid + a one-line note)
- Modify: `README.md`, `README_CN.md` (feature list)

- [ ] **Step 1: Update `CLAUDE.md`**

In the `Services["Service Layer — all @Observable"]` mermaid block, add a node after the `WS["WeatherService<br/>wttr.in"]` line:

```
        UQS["UsageQuotaService<br/>Claude oauth/usage 5h/7d quota"]
```

And in the **Project Structure** prose / Services description, no change needed beyond the diagram. Add one sentence under the "AI Service Architecture" section's closing paragraph:

> **Usage quota:** `UsageQuotaService` reads the Claude OAuth token (Keychain `Claude Code-credentials`, falling back to `~/.claude/.credentials.json`) and polls `GET /api/oauth/usage` to surface the 5-hour / 7-day quota as a card in `AIChatTab`. It is `LifecycleAware` (active only while the tab is visible) and throttles refreshes to 60s.

- [ ] **Step 2: Update `README.md` feature list**

Add to the feature bullet list (near the AI CLI monitoring feature):

```markdown
- **Claude usage quota** — shows your Claude Code 5-hour and 7-day quota (utilization % + reset countdown) as a card in the AI tab, read from the OAuth usage endpoint.
```

- [ ] **Step 3: Update `README_CN.md` feature list**

Add the Chinese equivalent near the AI CLI monitoring feature:

```markdown
- **Claude 用量配额** —— 在 AI 标签页以卡片展示 Claude Code 的 5 小时 / 7 天配额(使用率 % + 重置倒计时),数据来自 OAuth 用量接口。
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md README_CN.md
git commit -m "docs(quota): document Claude usage quota card"
```

---

## Final verification

- [ ] Run the full test suite: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'` — all pass.
- [ ] Build the app and manually confirm: open the notch → AI tab with Claude enabled → the quota card shows `5h` / `7d` rows with progress bars, percentages, and countdowns (e.g. `6d3h`). Click refresh → spins, values update. (This machine has a live Keychain credential, verified during design.)
- [ ] Merge `feature/claude-usage-quota` → `develop` (per Git Flow).

## Self-review notes (addressed)

- **Spec coverage:** Keychain-primary + file-fallback (Task 2), microsecond `resets_at` regression (Task 1 `parseResetDateMicroseconds`/`parseQuotaRealPayload`), throttle + 5-min timer + visible-only (Task 2 `setActive`/`refresh`), card placement above session list (Task 4), localized labels (Task 5). All present.
- **Type consistency:** `ClaudeUsageQuota`, `QuotaTier.window: QuotaWindow`, `UsageQuotaFormatter.countdown(...) -> CountdownResult`, `UsageQuotaService.refresh(force:)` / `quota` / `isRefreshing` used identically across tasks.
- **No placeholders:** every code/command step is concrete.
