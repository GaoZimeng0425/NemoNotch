# Gemini Usage Quota Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Gemini's per-model usage quota in the AI tab's quota card/meters alongside Claude Code and Codex, gated by `AppSettings.geminiEnabled`.

**Architecture:** Port CodexBar's production `GeminiStatusProbe` into NemoNotch's `UsageQuotaService` shape — read `~/.gemini/oauth_creds.json`, refresh the OAuth token (client_id/secret extracted at runtime from the installed gemini-cli, written back to the creds file), resolve the Cloud Code project via `loadCodeAssist`, then `retrieveUserQuota`. Buckets collapse per model (lowest remaining fraction) into the existing `ProviderUsageQuota`/`QuotaTier` model.

**Tech Stack:** Swift 6, SwiftUI, Foundation `URLSession`, `Process` (login-shell `which`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-06-15-gemini-quota-design.md`

**Reference:** `/Users/gaozimeng/Learn/macOS/CodexBar/Sources/CodexBarCore/Providers/Gemini/GeminiStatusProbe.swift`

---

## File Structure

- **Modify** `NemoNotch/Models/UsageQuota.swift` — add `.gemini` provider, `.gemini(label:)` window, `GeminiAuthType`, `GeminiOAuthCredential` + `parseGeminiCredentials`, `parseGeminiQuota` + `geminiModelShortName` + wire structs.
- **Create** `NemoNotch/Services/GeminiOAuthClientLocator.swift` — locate gemini-cli + extract OAuth client_id/secret from its JS.
- **Modify** `NemoNotch/Services/UsageQuotaService.swift` — Gemini fetch path + `refresh(force:)` integration.
- **Modify** `NemoNotch/Tabs/UsageQuotaCardView.swift` — render Gemini in full card + compact meters; 3-provider compact layout.
- **Modify** `NemoNotchTests/UsageQuotaTests.swift` — parser/credential/regex/short-name tests.
- **Modify** `CLAUDE.md`, `README.md`, `README_CN.md`, `docs/macos-cookbook.md` — docs.

**Test command (suite):**
```
xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests
```

---

## Task 1: Data model — provider, window, auth type, credential

**Files:**
- Modify: `NemoNotch/Models/UsageQuota.swift`
- Test: `NemoNotchTests/UsageQuotaTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to the `// MARK: - Credential parsing` area of `NemoNotchTests/UsageQuotaTests.swift`:

```swift
    // MARK: - Gemini credential parsing

    @Test func parseGeminiCredentialValid() throws {
        let json = #"{"access_token":"acc-1","refresh_token":"ref-1","expiry_date":1779783180264,"id_token":"x"}"#
        let cred = try UsageCredentialParser.parseGeminiCredentials(data: Data(json.utf8))
        #expect(cred.accessToken == "acc-1")
        #expect(cred.refreshToken == "ref-1")
        #expect(cred.expiryDate == Date(timeIntervalSince1970: 1779783180.264))
        #expect(cred.status == .valid)
    }

    @Test func parseGeminiCredentialNoTokens() throws {
        let json = #"{"scope":"openid"}"#
        let cred = try UsageCredentialParser.parseGeminiCredentials(data: Data(json.utf8))
        #expect(cred.accessToken == nil)
        #expect(cred.refreshToken == nil)
        #expect(cred.status == .notFound)
    }

    @Test func parseGeminiCredentialBadJSON() throws {
        let cred = try UsageCredentialParser.parseGeminiCredentials(data: Data("not json".utf8))
        #expect(cred.status == .parseError)
    }

    @Test func geminiAuthTypeRawValues() {
        #expect(GeminiAuthType(rawValue: "oauth-personal") == .oauthPersonal)
        #expect(GeminiAuthType(rawValue: "api-key") == .apiKey)
        #expect(GeminiAuthType(rawValue: "vertex-ai") == .vertexAI)
        #expect(GeminiAuthType(rawValue: "nonsense") == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests`
Expected: FAIL — `parseGeminiCredentials`, `GeminiOAuthCredential`, `GeminiAuthType` don't exist (compile error).

- [ ] **Step 3: Add `.gemini` to `QuotaProvider`**

In `UsageQuota.swift`, edit the `QuotaProvider` enum:

```swift
enum QuotaProvider: String, CaseIterable, Sendable {
    case claude
    case codex
    case gemini

    /// Brand name shown as the section header (verbatim, not localized).
    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }
}
```

- [ ] **Step 4: Add `.gemini(label:)` to `QuotaWindow`**

```swift
enum QuotaWindow: Hashable, Sendable {
    case fiveHour
    case sevenDay
    case sevenDayOpus
    case sevenDaySonnet
    case rolling(minutes: Int)
    /// Gemini per-model daily quota; carries a short display label (e.g. "2.5 Pro").
    case gemini(label: String)
}
```

- [ ] **Step 5: Add `GeminiAuthType` and `GeminiOAuthCredential`**

Add near the other model types in `UsageQuota.swift` (e.g. after `UsageCredential`):

```swift
/// Gemini CLI auth mode from `~/.gemini/settings.json` (`security.auth.selectedType`).
enum GeminiAuthType: String, Sendable {
    case oauthPersonal = "oauth-personal"
    case apiKey = "api-key"
    case vertexAI = "vertex-ai"
    case unknown
}

/// OAuth credential read from `~/.gemini/oauth_creds.json`.
struct GeminiOAuthCredential: Equatable, Sendable {
    let accessToken: String?
    let refreshToken: String?
    let expiryDate: Date?
    let status: CredentialStatus
    let message: String?

    init(
        accessToken: String?,
        refreshToken: String?,
        expiryDate: Date?,
        status: CredentialStatus,
        message: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiryDate = expiryDate
        self.status = status
        self.message = message
    }
}
```

- [ ] **Step 6: Add `parseGeminiCredentials` to `UsageCredentialParser`**

Inside `enum UsageCredentialParser`, after `parseCodexCredentials`. Note the
`try?` on `jsonObject` — invalid JSON (the `parseGeminiCredentialBadJSON` test's
`"not json"`) must resolve to `.parseError`, not rethrow:

```swift
    /// Parses `~/.gemini/oauth_creds.json`:
    /// `{ "access_token": "...", "refresh_token": "...", "expiry_date": <ms epoch> }`.
    /// Status is `.valid` when any usable token exists, `.notFound` when none do,
    /// `.parseError` when the payload isn't a JSON object. The service decides
    /// whether to refresh based on `expiryDate`.
    static func parseGeminiCredentials(data: Data, now: Date = Date()) throws -> GeminiOAuthCredential {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return GeminiOAuthCredential(
                accessToken: nil, refreshToken: nil, expiryDate: nil,
                status: .parseError, message: "Gemini credentials JSON is not an object"
            )
        }
        let access = (root["access_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let refresh = (root["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var expiry: Date?
        if let ms = root["expiry_date"] as? Double { expiry = Date(timeIntervalSince1970: ms / 1000) }
        else if let ms = root["expiry_date"] as? Int { expiry = Date(timeIntervalSince1970: Double(ms) / 1000) }
        guard access != nil || refresh != nil else {
            return GeminiOAuthCredential(
                accessToken: nil, refreshToken: nil, expiryDate: nil,
                status: .notFound, message: "No Gemini tokens present"
            )
        }
        return GeminiOAuthCredential(
            accessToken: access, refreshToken: refresh, expiryDate: expiry, status: .valid
        )
    }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests`
Expected: PASS (all 4 new tests + existing).

- [ ] **Step 8: Commit**

```bash
git add NemoNotch/Models/UsageQuota.swift NemoNotchTests/UsageQuotaTests.swift
git commit -m "feat(quota): Gemini provider/window/credential model"
```

---

## Task 2: Parse Gemini quota response + model short name

**Files:**
- Modify: `NemoNotch/Models/UsageQuota.swift`
- Test: `NemoNotchTests/UsageQuotaTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `UsageQuotaTests.swift`:

```swift
    // MARK: - Gemini quota parsing

    @Test func parseGeminiQuotaCollapsesPerModel() throws {
        // Two token-type buckets for pro (keep the lower fraction = more used);
        // one for flash. Order by utilization descending.
        let json = """
        {"buckets":[
          {"modelId":"gemini-2.5-pro","tokenType":"REQUESTS","remainingFraction":0.4,"resetTime":"2026-06-16T00:00:00Z"},
          {"modelId":"gemini-2.5-pro","tokenType":"TOKENS","remainingFraction":0.1,"resetTime":"2026-06-16T00:00:00Z"},
          {"modelId":"gemini-2.5-flash","tokenType":"REQUESTS","remainingFraction":0.8,"resetTime":"2026-06-16T00:00:00Z"}
        ]}
        """
        let quota = try UsageQuotaParser.parseGeminiQuota(data: Data(json.utf8))
        #expect(quota.provider == .gemini)
        #expect(quota.status == .valid)
        #expect(quota.tiers.count == 2) // pro collapsed to one row
        // pro: 1 - 0.1 = 90% used (lowest fraction kept); flash: 1 - 0.8 = 20%
        #expect(quota.tiers[0].window == .gemini(label: "2.5 Pro"))
        #expect(abs(quota.tiers[0].utilization - 90.0) < 0.001)
        #expect(quota.tiers[1].window == .gemini(label: "2.5 Flash"))
        #expect(abs(quota.tiers[1].utilization - 20.0) < 0.001)
        #expect(quota.tiers[0].resetsAt != nil)
    }

    @Test func parseGeminiQuotaEmptyBuckets() throws {
        let quota = try UsageQuotaParser.parseGeminiQuota(data: Data(#"{"buckets":[]}"#.utf8))
        #expect(quota.status == .valid)
        #expect(quota.tiers.isEmpty)
    }

    @Test func parseGeminiQuotaSkipsBucketsMissingFraction() throws {
        // 100%-quota bucket omits remainingFraction → skipped, not crashed.
        let json = #"{"buckets":[{"modelId":"gemini-2.5-pro","tokenType":"REQUESTS","resetTime":"2026-06-16T00:00:00Z"}]}"#
        let quota = try UsageQuotaParser.parseGeminiQuota(data: Data(json.utf8))
        #expect(quota.tiers.isEmpty)
    }

    @Test func geminiModelShortNames() {
        #expect(UsageQuotaParser.geminiModelShortName("gemini-2.5-pro") == "2.5 Pro")
        #expect(UsageQuotaParser.geminiModelShortName("gemini-2.5-flash") == "2.5 Flash")
        #expect(UsageQuotaParser.geminiModelShortName("gemini-2.5-flash-lite") == "2.5 Flash Lite")
        #expect(UsageQuotaParser.geminiModelShortName("gemini-exp-1206") == "exp-1206")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests`
Expected: FAIL — `parseGeminiQuota` / `geminiModelShortName` undefined.

- [ ] **Step 3: Add the wire-decoding structs**

In the `// MARK: - Wire decoding` section of `UsageQuota.swift`, add:

```swift
private struct GeminiQuotaResponse: Decodable {
    let buckets: [GeminiQuotaBucket]?
}

private struct GeminiQuotaBucket: Decodable {
    let modelId: String?
    let tokenType: String?
    let remainingFraction: Double?
    let resetTime: String?
}
```

- [ ] **Step 4: Add `parseGeminiQuota` and `geminiModelShortName`**

Inside `enum UsageQuotaParser`, after `parseCodexQuota`:

```swift
    /// Parses Gemini's `retrieveUserQuota` response. Collapses each model's
    /// buckets to the lowest `remainingFraction` (most-constrained token type)
    /// and maps to `utilization = (1 - fraction) * 100`, descending.
    static func parseGeminiQuota(data: Data, fetchedAt: Date = Date()) throws -> ProviderUsageQuota {
        let response = try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
        let buckets = response.buckets ?? []

        var byModel: [String: (fraction: Double, reset: String?)] = [:]
        for bucket in buckets {
            guard let model = bucket.modelId, let fraction = bucket.remainingFraction else { continue }
            if let existing = byModel[model] {
                if fraction < existing.fraction { byModel[model] = (fraction, bucket.resetTime) }
            } else {
                byModel[model] = (fraction, bucket.resetTime)
            }
        }

        // utilization descending = remaining fraction ascending; tie-break by model id.
        let tiers = byModel
            .sorted { lhs, rhs in
                lhs.value.fraction != rhs.value.fraction
                    ? lhs.value.fraction < rhs.value.fraction
                    : lhs.key < rhs.key
            }
            .map { model, info -> QuotaTier in
                let utilization = min(max((1 - info.fraction) * 100, 0), 100)
                return QuotaTier(
                    window: .gemini(label: geminiModelShortName(model)),
                    utilization: utilization,
                    resetsAt: info.reset.flatMap(parseResetDate)
                )
            }

        return ProviderUsageQuota(provider: .gemini, status: .valid, tiers: tiers, fetchedAt: fetchedAt)
    }

    /// `gemini-2.5-pro` → "2.5 Pro", `gemini-2.5-flash-lite` → "2.5 Flash Lite",
    /// unknown families fall back to the id minus the `gemini-` prefix.
    static func geminiModelShortName(_ modelId: String) -> String {
        let lower = modelId.lowercased()
        let version = modelId.split(separator: "-")
            .first { $0.contains(".") && $0.allSatisfy { $0.isNumber || $0 == "." } }
            .map(String.init)
        let family: String
        if lower.contains("flash-lite") { family = "Flash Lite" }
        else if lower.contains("flash") { family = "Flash" }
        else if lower.contains("pro") { family = "Pro" }
        else { return modelId.replacingOccurrences(of: "gemini-", with: "") }
        if let version { return "\(version) \(family)" }
        return family
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Models/UsageQuota.swift NemoNotchTests/UsageQuotaTests.swift
git commit -m "feat(quota): parse Gemini quota buckets + model short names"
```

---

## Task 3: OAuth client locator (extract client_id/secret from gemini-cli)

**Files:**
- Create: `NemoNotch/Services/GeminiOAuthClientLocator.swift`
- Test: `NemoNotchTests/UsageQuotaTests.swift`

- [ ] **Step 1: Write the failing test (regex parse only — binary location is integration, untested)**

Append to `UsageQuotaTests.swift`:

```swift
    // MARK: - Gemini OAuth client extraction

    @Test func geminiOAuthClientParse() {
        let js = """
        const OAUTH_CLIENT_ID = '681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com';
        const OAUTH_CLIENT_SECRET = 'xxxx-redacted-client-secret-xxxx';
        """
        let creds = GeminiOAuthClientLocator.parse(from: js)
        #expect(creds?.clientId == "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com")
        #expect(creds?.clientSecret == "xxxx-redacted-client-secret-xxxx")
    }

    @Test func geminiOAuthClientParseMissing() {
        #expect(GeminiOAuthClientLocator.parse(from: "const FOO = 'bar';") == nil)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests`
Expected: FAIL — `GeminiOAuthClientLocator` undefined.

- [ ] **Step 3: Create the locator**

Create `NemoNotch/Services/GeminiOAuthClientLocator.swift`:

```swift
import Foundation

/// Locates the installed gemini-cli and extracts its OAuth client_id/secret
/// from the bundled JS. Ported from CodexBar's GeminiStatusProbe. These are
/// public "installed application" credentials embedded in gemini-cli's source;
/// reading them at runtime means a Google key rotation can't break us.
enum GeminiOAuthClientLocator {
    struct ClientCredentials: Equatable, Sendable {
        let clientId: String
        let clientSecret: String
    }

    // MARK: - Pure parsing (unit-tested)

    /// Regex-extracts `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET` from JS source.
    static func parse(from content: String) -> ClientCredentials? {
        guard let id = firstMatch(#"OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]"#, in: content),
              let secret = firstMatch(#"OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]"#, in: content)
        else { return nil }
        return ClientCredentials(clientId: id, clientSecret: secret)
    }

    private static func firstMatch(_ pattern: String, in content: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let captured = Range(match.range(at: 1), in: content) else { return nil }
        return String(content[captured])
    }

    // MARK: - Resolution (integration)

    /// Full resolution: locate the gemini binary, then read its OAuth constants.
    static func resolve() -> ClientCredentials? {
        guard let binary = locateGeminiBinary() else {
            LogService.warn("Gemini OAuth: gemini binary not found", category: "UsageQuotaService")
            return nil
        }
        let real = URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
        if let creds = fromLegacyPaths(realGeminiPath: real) { return creds }
        if let root = findPackageRoot(startingAt: real), let creds = fromPackageRoot(root) { return creds }
        LogService.warn("Gemini OAuth: could not extract client credentials", category: "UsageQuotaService")
        return nil
    }

    private static func locateGeminiBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.bun/bin/gemini",
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            "\(home)/.npm-global/bin/gemini",
            "\(home)/.local/bin/gemini",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) { return path }
        // GUI apps don't inherit the user's shell PATH, so fall back to a login shell.
        return loginShellWhich("gemini")
    }

    private static func loginShellWhich(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "which \(tool)"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    private static let oauthFile = "dist/src/code_assist/oauth2.js"

    private static func fromLegacyPaths(realGeminiPath: String) -> ClientCredentials? {
        let binDir = (realGeminiPath as NSString).deletingLastPathComponent
        let baseDir = (binDir as NSString).deletingLastPathComponent
        let nested = "node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/\(oauthFile)"
        let nixShare = "share/gemini-cli/node_modules/@google/gemini-cli-core/\(oauthFile)"
        let paths = [
            "\(baseDir)/libexec/lib/\(nested)",
            "\(baseDir)/lib/\(nested)",
            "\(baseDir)/\(nixShare)",
            "\(baseDir)/../gemini-cli-core/\(oauthFile)",
            "\(baseDir)/node_modules/@google/gemini-cli-core/\(oauthFile)",
        ]
        for path in paths {
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               let creds = parse(from: content) { return creds }
        }
        return nil
    }

    /// Ascend ≤8 dirs looking for `@google/gemini-cli`'s package.json, then read
    /// `oauth2.js`; falls back to scanning the bundle (this machine's bun layout).
    private static func findPackageRoot(startingAt path: String) -> String? {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: current.path, isDirectory: &isDir) || !isDir.boolValue {
            current.deleteLastPathComponent()
        }
        for _ in 0...8 {
            let pkg = current.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: pkg),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["name"] as? String == "@google/gemini-cli" {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    private static func fromPackageRoot(_ root: String) -> ClientCredentials? {
        let candidates = [
            "\(root)/\(oauthFile)",
            "\(root)/node_modules/@google/gemini-cli-core/\(oauthFile)",
        ]
        for path in candidates {
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               let creds = parse(from: content) { return creds }
        }
        return fromBundle(packageRoot: root)
    }

    /// BFS the `bundle/` dir from gemini.js following relative `./*.js` imports,
    /// then any sibling `.js`. Matches gemini-cli's single-file bundle layout.
    private static func fromBundle(packageRoot: String) -> ClientCredentials? {
        let bundleRoot = URL(fileURLWithPath: packageRoot).appendingPathComponent("bundle", isDirectory: true)
        let entry = bundleRoot.appendingPathComponent("gemini.js")
        guard FileManager.default.fileExists(atPath: entry.path) else { return nil }

        var pending = [entry]
        var visited = Set<String>()
        while !pending.isEmpty {
            let url = pending.removeFirst()
            let key = url.standardizedFileURL.path
            guard visited.insert(key).inserted,
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let creds = parse(from: content) { return creds }
            for imp in relativeImports(in: content) {
                let next = URL(fileURLWithPath: imp, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                if next.path.hasPrefix(bundleRoot.path) { pending.append(next) }
            }
        }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: bundleRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        for url in files where url.pathExtension == "js" && !visited.contains(url.standardizedFileURL.path) {
            if let content = try? String(contentsOf: url, encoding: .utf8),
               let creds = parse(from: content) { return creds }
        }
        return nil
    }

    private static func relativeImports(in content: String) -> [String] {
        let patterns = [
            #"(?:import|export)\s+(?:[^;]*?\s+from\s+)?["'](\./[^"']+\.js)["']"#,
            #"import\(\s*["'](\./[^"']+\.js)["']\s*\)"#,
        ]
        var out: [String] = []
        var seen = Set<String>()
        let range = NSRange(content.startIndex..., in: content)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: content, range: range) {
                guard let r = Range(match.range(at: 1), in: content) else { continue }
                let path = String(content[r])
                if seen.insert(path).inserted { out.append(path) }
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests`
Expected: PASS.

(Integration — actually locating the binary on this machine — is verified live
in Task 6, Step 2.)

- [ ] **Step 5: Commit**

```bash
git add NemoNotch/Services/GeminiOAuthClientLocator.swift NemoNotchTests/UsageQuotaTests.swift
git commit -m "feat(quota): locate gemini-cli + extract OAuth client credentials"
```

---

## Task 4: Service — Gemini fetch path + refresh integration

**Files:**
- Modify: `NemoNotch/Services/UsageQuotaService.swift`

(No new unit test — networking/Keychain integration is untested per the existing Claude/Codex policy. Verified live in Task 6.)

- [ ] **Step 1: Add Gemini URLs, credential flag, and project cache**

In `UsageQuotaService`, after the Codex stored properties (the `codexUsageURL` line block), add:

```swift
    private let geminiCredentialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/oauth_creds.json")
    private let geminiSettingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/settings.json")
    private let geminiTokenRefreshURL = URL(string: "https://oauth2.googleapis.com/token")!
    private let geminiLoadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private let geminiQuotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    private let geminiProjectsURL = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects")!

    /// Whether a usable Gemini OAuth credential exists (drives section visibility).
    private(set) var hasGeminiCredential = false
    /// Cloud Code project id, resolved once per process run.
    private var geminiProjectID: String?
```

- [ ] **Step 2: Compute `hasGeminiCredential` at init**

In `init()`, after `hasCodexCredential = codexCredentialPresent()`:

```swift
        hasGeminiCredential = geminiCredentialPresent()
```

- [ ] **Step 3: Integrate Gemini into `refresh(force:)`**

In `refresh(force:)`, replace the credential-recompute + concurrent fetch block:

```swift
        hasCodexCredential = codexCredentialPresent()
        async let claudeTask = fetchClaude()
        async let codexTask = fetchCodexIfPresent()
        let (claudeResult, codexResult) = await (claudeTask, codexTask)

        var next: [QuotaProvider: ProviderUsageQuota] = [:]
        next[.claude] = backfilled(claudeResult, from: quotas[.claude])
        if let codexResult { next[.codex] = backfilled(codexResult, from: quotas[.codex]) }
        quotas = next
        lastFetched = Date()
```

with:

```swift
        hasCodexCredential = codexCredentialPresent()
        hasGeminiCredential = geminiCredentialPresent()
        async let claudeTask = fetchClaude()
        async let codexTask = fetchCodexIfPresent()
        async let geminiTask = fetchGeminiIfPresent()
        let (claudeResult, codexResult, geminiResult) = await (claudeTask, codexTask, geminiTask)

        var next: [QuotaProvider: ProviderUsageQuota] = [:]
        next[.claude] = backfilled(claudeResult, from: quotas[.claude])
        if let codexResult { next[.codex] = backfilled(codexResult, from: quotas[.codex]) }
        if let geminiResult { next[.gemini] = backfilled(geminiResult, from: quotas[.gemini]) }
        quotas = next
        lastFetched = Date()
```

- [ ] **Step 4: Add the Gemini fetch path**

Add a new `// MARK: - Gemini` section after the Codex section (before `// MARK: - Keychain`):

```swift
    // MARK: - Gemini

    private func geminiCredentialPresent() -> Bool {
        guard FileManager.default.fileExists(atPath: geminiCredentialsURL.path) else { return false }
        switch geminiAuthType() {
        case .apiKey, .vertexAI: return false
        case .oauthPersonal, .unknown: return true
        }
    }

    private func geminiAuthType() -> GeminiAuthType {
        guard let data = try? Data(contentsOf: geminiSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = json["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any],
              let selected = auth["selectedType"] as? String else { return .unknown }
        return GeminiAuthType(rawValue: selected) ?? .unknown
    }

    private func fetchGeminiIfPresent() async -> ProviderUsageQuota? {
        guard hasGeminiCredential else { return nil }
        return await fetchGemini()
    }

    private func fetchGemini() async -> ProviderUsageQuota {
        let now = Date()
        let credential: GeminiOAuthCredential
        do {
            let data = try Data(contentsOf: geminiCredentialsURL)
            credential = try UsageCredentialParser.parseGeminiCredentials(data: data, now: now)
        } catch {
            LogService.error("Gemini quota: credential unreadable: \(error.localizedDescription)", category: "UsageQuotaService")
            return ProviderUsageQuota(provider: .gemini, status: .notFound, fetchedAt: now, errorMessage: error.localizedDescription)
        }
        guard credential.status != .parseError else {
            return ProviderUsageQuota(provider: .gemini, status: .parseError, fetchedAt: now, errorMessage: credential.message)
        }

        guard let accessToken = await resolveGeminiAccessToken(credential) else {
            return ProviderUsageQuota(provider: .gemini, status: .expired, fetchedAt: now, errorMessage: "Re-login required")
        }

        if geminiProjectID == nil {
            geminiProjectID = await resolveGeminiProject(accessToken: accessToken)
        }

        var request = URLRequest(url: geminiQuotaURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let project = geminiProjectID {
            request.httpBody = Data(#"{"project":"\#(project)"}"#.utf8)
        } else {
            request.httpBody = Data("{}".utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                geminiProjectID = nil
                LogService.warn("Gemini quota: HTTP 401", category: "UsageQuotaService")
                return ProviderUsageQuota(provider: .gemini, status: .expired, fetchedAt: now, errorMessage: "Re-login required")
            }
            guard (200 ..< 300).contains(status) else {
                LogService.error("Gemini quota: HTTP \(status)", category: "UsageQuotaService")
                return ProviderUsageQuota(provider: .gemini, status: .valid, fetchedAt: now, errorMessage: "HTTP \(status)")
            }
            let parsed = try UsageQuotaParser.parseGeminiQuota(data: data, fetchedAt: now)
            LogService.info("Gemini quota fetched: \(parsed.tiers.count) tiers", category: "UsageQuotaService")
            return parsed
        } catch {
            LogService.error("Gemini quota fetch failed: \(error.localizedDescription)", category: "UsageQuotaService")
            return ProviderUsageQuota(provider: .gemini, status: .valid, fetchedAt: now, errorMessage: error.localizedDescription)
        }
    }

    /// Returns a usable access token, refreshing (and writing back) when the
    /// stored one is missing or expired.
    private func resolveGeminiAccessToken(_ credential: GeminiOAuthCredential) async -> String? {
        let expired = credential.expiryDate.map { $0 < Date() } ?? true
        if let token = credential.accessToken, !expired { return token }
        guard let refresh = credential.refreshToken, !refresh.isEmpty else {
            LogService.warn("Gemini quota: token expired, no refresh token", category: "UsageQuotaService")
            return nil
        }
        return await refreshGeminiToken(refreshToken: refresh)
    }

    private func refreshGeminiToken(refreshToken: String) async -> String? {
        guard let client = GeminiOAuthClientLocator.resolve() else {
            LogService.error("Gemini quota: OAuth client credentials not found", category: "UsageQuotaService")
            return nil
        }
        var request = URLRequest(url: geminiTokenRefreshURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id=\(client.clientId)",
            "client_secret=\(client.clientSecret)",
            "refresh_token=\(refreshToken)",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String else {
                LogService.error("Gemini token refresh failed: HTTP \(status)", category: "UsageQuotaService")
                return nil
            }
            writeBackGeminiToken(refreshResponse: json)
            LogService.info("Gemini token refreshed", category: "UsageQuotaService")
            return token
        } catch {
            LogService.error("Gemini token refresh error: \(error.localizedDescription)", category: "UsageQuotaService")
            return nil
        }
    }

    /// Persists the refreshed token back to `~/.gemini/oauth_creds.json` (atomic),
    /// matching gemini-cli's own behavior so the CLI and NemoNotch stay in sync.
    private func writeBackGeminiToken(refreshResponse: [String: Any]) {
        guard let existing = try? Data(contentsOf: geminiCredentialsURL),
              var json = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return }
        if let access = refreshResponse["access_token"] { json["access_token"] = access }
        if let expiresIn = refreshResponse["expires_in"] as? Double {
            json["expiry_date"] = (Date().timeIntervalSince1970 + expiresIn) * 1000
        }
        if let idToken = refreshResponse["id_token"] { json["id_token"] = idToken }
        if let updated = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? updated.write(to: geminiCredentialsURL, options: .atomic)
        }
    }

    /// loadCodeAssist → project; falls back to cloudresourcemanager; nil = send `{}`.
    private func resolveGeminiProject(accessToken: String) async -> String? {
        var request = URLRequest(url: geminiLoadCodeAssistURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8)
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let project = geminiProjectID(from: json) {
            LogService.info("Gemini project resolved via loadCodeAssist", category: "UsageQuotaService")
            return project
        }

        var probe = URLRequest(url: geminiProjectsURL, timeoutInterval: 10)
        probe.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let (data, response) = try? await URLSession.shared.data(for: probe),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = json["projects"] as? [[String: Any]] {
            for project in projects {
                guard let id = project["projectId"] as? String else { continue }
                if id.hasPrefix("gen-lang-client") { return id }
                if let labels = project["labels"] as? [String: String], labels["generative-language"] != nil { return id }
            }
        }

        LogService.warn("Gemini project unresolved; sending empty quota body", category: "UsageQuotaService")
        return nil
    }

    private func geminiProjectID(from json: [String: Any]) -> String? {
        if let s = json["cloudaicompanionProject"] as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let obj = json["cloudaicompanionProject"] as? [String: Any] {
            return (obj["id"] as? String) ?? (obj["projectId"] as? String)
        }
        return nil
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add NemoNotch/Services/UsageQuotaService.swift
git commit -m "feat(quota): Gemini fetch path (refresh + project + quota)"
```

---

## Task 5: UI — render Gemini in card + compact meters

**Files:**
- Modify: `NemoNotch/Tabs/UsageQuotaCardView.swift`

- [ ] **Step 1: Add Gemini to `visibleProviders` (full card)**

In `UsageQuotaCardView`, replace its `visibleProviders`:

```swift
    private var visibleProviders: [QuotaProvider] {
        var result: [QuotaProvider] = []
        if appSettings.claudeEnabled { result.append(.claude) }
        if service.hasCodexCredential { result.append(.codex) }
        if appSettings.geminiEnabled, service.hasGeminiCredential { result.append(.gemini) }
        return result
    }
```

- [ ] **Step 2: Handle `.gemini` in the full card's `label(for:)`**

Replace `UsageQuotaCardView.label(for:)`:

```swift
    private func label(for window: QuotaWindow) -> Text {
        switch window {
        case .fiveHour: Text("quota.window.5h")
        case .sevenDay: Text("quota.window.7d")
        case .sevenDayOpus: Text("quota.window.7d_opus")
        case .sevenDaySonnet: Text("quota.window.7d_sonnet")
        case let .rolling(minutes): Text(verbatim: UsageQuotaFormatter.windowLabel(minutes: minutes))
        case let .gemini(label): Text(verbatim: label)
        }
    }
```

- [ ] **Step 3: Add Gemini to `visibleProviders` (compact)**

In `UsageQuotaCompactView`, replace its `visibleProviders` identically:

```swift
    private var visibleProviders: [QuotaProvider] {
        var result: [QuotaProvider] = []
        if appSettings.claudeEnabled { result.append(.claude) }
        if service.hasCodexCredential { result.append(.codex) }
        if appSettings.geminiEnabled, service.hasGeminiCredential { result.append(.gemini) }
        return result
    }
```

- [ ] **Step 4: Allow up to 3 rows in the compact layout**

Replace `UsageQuotaCompactView.rows`:

```swift
    /// At most one primary row per visible provider (≤3: Claude, Codex, Gemini).
    /// A lone provider also gets its secondary tier as a second row.
    private var rows: [(provider: QuotaProvider, slot: Slot)] {
        let providers = visibleProviders
        if providers.count <= 1 {
            guard let only = providers.first else { return [] }
            return [(only, .primary), (only, .secondary)]
        }
        return providers.map { ($0, .primary) }
    }
```

- [ ] **Step 5: Handle `.gemini` in compact `windowShortLabel` and provider prefix**

Replace `UsageQuotaCompactView.windowShortLabel(_:)`:

```swift
    private func windowShortLabel(_ window: QuotaWindow) -> String {
        switch window {
        case .fiveHour: return "5h"
        case .sevenDay, .sevenDayOpus, .sevenDaySonnet: return "7d"
        case let .rolling(minutes): return UsageQuotaFormatter.windowLabel(minutes: minutes)
        case let .gemini(label): return label
        }
    }
```

Replace the prefix line in `UsageQuotaCompactView.label(provider:tier:)`:

```swift
    private func label(provider: QuotaProvider, tier: QuotaTier?) -> String {
        let win = tier.map { windowShortLabel($0.window) } ?? "--"
        guard visibleProviders.count != 1 else { return win }
        let prefix = switch provider {
        case .claude: "C"
        case .codex: "Cx"
        case .gemini: "G"
        }
        return "\(prefix) \(win)"
    }
```

- [ ] **Step 6: Build to verify it compiles**

Run: `xcodebuild build -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED (no non-exhaustive-switch warnings for `QuotaWindow`).

- [ ] **Step 7: Commit**

```bash
git add NemoNotch/Tabs/UsageQuotaCardView.swift
git commit -m "feat(quota): render Gemini quota in card + compact meters"
```

---

## Task 6: Live verification + docs

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `README_CN.md`, `docs/macos-cookbook.md`

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -project NemoNotch.xcodeproj -scheme NemoNotch -destination 'platform=macOS' -only-testing:NemoNotchTests/UsageQuotaTests`
Expected: PASS (all Gemini + pre-existing tests).

- [ ] **Step 2: Live-verify against the real account**

Build & run the app, open the AI tab, open the quota popover. Confirm a
"Gemini" section appears with one row per model and a non-`--` percentage.
Cross-check the logs:

Run: `grep -i gemini ~/.NemoNotch/logs/*.log | tail -20`
Expected: lines for "Gemini token refreshed", "Gemini project resolved …",
"Gemini quota fetched: N tiers". If you instead see "OAuth client credentials
not found", the locator missed this install layout — capture the gemini binary
path (`which gemini`) and revisit `GeminiOAuthClientLocator.locateGeminiBinary`.

- [ ] **Step 3: Update `CLAUDE.md`**

In the "Usage quota" paragraph (Architecture section), replace the final
sentence "Gemini quota is a planned follow-up (needs OAuth token refresh +
project resolution)." with:

```
Gemini quota (free-tier personal Google account) is fetched via a three-call Cloud Code flow: refresh the OAuth token (`POST oauth2.googleapis.com/token`; client_id/secret are extracted at runtime from the installed gemini-cli's bundled JS by `GeminiOAuthClientLocator`, and the refreshed token is written back to `~/.gemini/oauth_creds.json` to stay in sync with the CLI) → resolve the project (`:loadCodeAssist`, with a `cloudresourcemanager` fallback) → `:retrieveUserQuota`. Credentials live in the plain file `~/.gemini/oauth_creds.json` (no Keychain). `settings.json`'s `security.auth.selectedType` gates out api-key/vertex-ai auth. Per-model buckets collapse to the lowest remaining fraction and render as `QuotaWindow.gemini(label:)` rows.
```

- [ ] **Step 4: Update `README.md` and `README_CN.md`**

Find the usage-quota feature bullet mentioning Claude + Codex and add Gemini.
In `README.md`, change the quota line to read "Claude Code, Codex, and Gemini
usage quotas". In `README_CN.md`, change it to "Claude Code、Codex 和 Gemini
用量额度".

- [ ] **Step 5: Update `docs/macos-cookbook.md` §14.3**

Append a short subsection after the existing Keychain quota entry:

```
**Gemini quota (no Keychain).** Gemini stores its OAuth credential in the plain
file `~/.gemini/oauth_creds.json` (mode 0600, readable by the user's own GUI
app), so no Keychain ACL dance is needed. The short-lived access token is
usually expired, so `UsageQuotaService` refreshes it via
`POST oauth2.googleapis.com/token` using client_id/secret extracted at runtime
from the installed gemini-cli's bundled JS (`GeminiOAuthClientLocator` — locate
binary → resolve symlink → read `oauth2.js` / scan `bundle/`), then writes the
refreshed token back to the creds file. Quota needs a Cloud Code project, so
`:loadCodeAssist` resolves `cloudaicompanionProject` (cloudresourcemanager
fallback) before `:retrieveUserQuota`. No new private API; no new
`@unchecked Sendable` boundary.
```

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md README.md README_CN.md docs/macos-cookbook.md
git commit -m "docs(quota): document Gemini quota flow"
```

---

## Self-Review Notes

- **Spec coverage:** provider/window/credential (Task 1) · per-model parse + short name (Task 2) · runtime client extraction + auth guard (Tasks 3-4) · refresh write-back + project fallback (Task 4) · UI incl. 3-provider compact (Task 5) · docs + live verify (Task 6). All spec sections mapped.
- **Out of scope (per spec):** account email/plan display, `onboardUser`, fnm-managed installs — none of these have tasks, intentionally.
- **Type consistency:** `parseGeminiCredentials`, `parseGeminiQuota`, `geminiModelShortName`, `GeminiOAuthClientLocator.{parse,resolve,ClientCredentials}`, `GeminiAuthType`, `QuotaWindow.gemini(label:)`, `QuotaProvider.gemini` used identically across tasks.
