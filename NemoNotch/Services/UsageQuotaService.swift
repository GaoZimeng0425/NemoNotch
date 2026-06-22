import Darwin
import Foundation
import LocalAuthentication
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
    /// Local read cache of the last good Claude token (accessToken + expiresAt only).
    /// Lets refreshes skip the Keychain entirely; see `readClaudeCredential`.
    private let claudeCacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".NemoNotch/claude-cred.json")
    private let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let codexKeychainService = "Codex Auth"
    private let codexAuthURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")
    private let codexUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

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

    private let throttleInterval: TimeInterval = 60
    private let refreshInterval: TimeInterval = 300

    private var timer: Timer?
    private var lastFetched: Date?

    init() {
        LogService.info("UsageQuotaService init", category: "UsageQuotaService")
        hasCodexCredential = codexCredentialPresent()
        hasGeminiCredential = geminiCredentialPresent()
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
    }

    /// Re-applies a future reset time from the previous fetch to any fresh tier
    /// that came back without one.
    private func backfilled(
        _ quota: ProviderUsageQuota,
        from previous: ProviderUsageQuota?,
        now: Date = Date()
    ) -> ProviderUsageQuota {
        guard !quota.tiers.isEmpty, let previous else { return quota }
        let tiers = quota.tiers.map { tier in
            tier.backfillingReset(from: previous.tiers.first { $0.window == tier.window }, now: now)
        }
        return ProviderUsageQuota(
            provider: quota.provider,
            status: quota.status,
            tiers: tiers,
            fetchedAt: quota.fetchedAt,
            errorMessage: quota.errorMessage
        )
    }

    // MARK: - Claude

    private func fetchClaude() async -> ProviderUsageQuota {
        let now = Date()
        let credential = readClaudeCredential(now: now)
        guard let token = credential.token else {
            LogService.warn("Claude quota: no credential (status \(credential.status))", category: "UsageQuotaService")
            return ProviderUsageQuota(
                provider: .claude,
                status: credential.status,
                fetchedAt: now,
                errorMessage: credential.message
            )
        }
        if credential.status == .expired {
            return ProviderUsageQuota(
                provider: .claude,
                status: .expired,
                fetchedAt: now,
                errorMessage: credential.message
            )
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
                // The cached token was accepted by our clock check but rejected by
                // the server — drop the cache so the next refresh re-resolves a fresh
                // token from the CLI file / Keychain.
                invalidateClaudeCache()
                return ProviderUsageQuota(
                    provider: .claude,
                    status: .expired,
                    fetchedAt: now,
                    errorMessage: "Re-login required"
                )
            }
            guard (200 ..< 300).contains(status) else {
                LogService.error("Claude quota: HTTP \(status)", category: "UsageQuotaService")
                return ProviderUsageQuota(
                    provider: .claude,
                    status: .valid,
                    fetchedAt: now,
                    errorMessage: "HTTP \(status)"
                )
            }
            let parsed = try UsageQuotaParser.parseClaudeCodeQuota(data: data, fetchedAt: now)
            LogService.info("Claude quota fetched: \(parsed.tiers.count) tiers", category: "UsageQuotaService")
            return parsed
        } catch {
            LogService.error("Claude quota fetch failed: \(error.localizedDescription)", category: "UsageQuotaService")
            return ProviderUsageQuota(
                provider: .claude,
                status: .valid,
                fetchedAt: now,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func readClaudeCredential(now: Date) -> UsageCredential {
        // Local cache first — a copy of the last good token under ~/.NemoNotch/.
        // It survives sleep without touching the Keychain, so the common refresh
        // path no longer re-validates the ad-hoc signature against the Keychain ACL
        // (which lapses across sleep and forced a re-authorize). The Keychain is
        // consulted only when this cache is absent or its token has expired.
        if let data = try? Data(contentsOf: claudeCacheURL),
           let cached = try? UsageCredentialParser.parseClaudeCredentials(data: data, now: now),
           cached.status == .valid {
            return cached
        }
        // Claude CLI's own file next — most users have ~/.claude/.credentials.json,
        // so this path never touches the Keychain (and never triggers its cross-app
        // prompt). Refresh the local cache from it on success.
        if FileManager.default.fileExists(atPath: claudeCredentialsURL.path) {
            do {
                let data = try Data(contentsOf: claudeCredentialsURL)
                let credential = try UsageCredentialParser.parseClaudeCredentials(data: data, now: now)
                if credential.status == .valid { writeClaudeCache(from: data) }
                return credential
            } catch {
                LogService.warn(
                    "Claude credential file unreadable, trying Keychain: \(error.localizedDescription)",
                    category: "UsageQuotaService"
                )
            }
        }
        // No usable cache or file — resolve from the Keychain without ever prompting
        // here, and cache the blob (token + expiry only) on success so subsequent
        // refreshes can skip the Keychain entirely.
        return readKeychainCredential(provider: .claude, service: claudeKeychainService) { data in
            let credential = try? UsageCredentialParser.parseClaudeCredentials(data: data, now: now)
            if credential?.status == .valid { self.writeClaudeCache(from: data) }
            return credential
        }
    }

    /// Writes a minimal copy of the Claude credential — accessToken + expiresAt
    /// only, deliberately NOT the refreshToken — to ~/.NemoNotch/claude-cred.json
    /// with 0600 permissions. This read cache lets refreshes avoid the Keychain
    /// (see `readClaudeCredential`); it is a plaintext copy of a secret, so it
    /// stores the least it can and is locked to the owner.
    private func writeClaudeCache(from raw: Data) {
        guard
            let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
            let entry = (root["claudeAiOauth"] ?? root["claude.ai_oauth"]) as? [String: Any],
            let token = entry["accessToken"] as? String, !token.isEmpty
        else { return }
        var minimal: [String: Any] = ["accessToken": token]
        if let expiresAt = entry["expiresAt"] { minimal["expiresAt"] = expiresAt }
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": minimal]) else { return }
        do {
            try FileManager.default.createDirectory(
                at: claudeCacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: claudeCacheURL, options: .atomic)
            // Atomic write renames a temp file in, so re-assert owner-only perms.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claudeCacheURL.path)
            LogService.debug("Claude credential cache written", category: "UsageQuotaService")
        } catch {
            LogService.warn(
                "Claude credential cache write failed: \(error.localizedDescription)",
                category: "UsageQuotaService"
            )
        }
    }

    /// Drops the local Claude cache so the next refresh re-resolves the token from
    /// the Keychain / CLI file. Called when the server rejects the cached token (401).
    private func invalidateClaudeCache() {
        guard FileManager.default.fileExists(atPath: claudeCacheURL.path) else { return }
        try? FileManager.default.removeItem(at: claudeCacheURL)
        LogService.info("Claude credential cache invalidated (401)", category: "UsageQuotaService")
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
            return ProviderUsageQuota(
                provider: .codex,
                status: credential.status,
                fetchedAt: now,
                errorMessage: credential.message
            )
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
                return ProviderUsageQuota(
                    provider: .codex,
                    status: .expired,
                    fetchedAt: now,
                    errorMessage: "Re-login required"
                )
            }
            guard (200 ..< 300).contains(status) else {
                LogService.error("Codex quota: HTTP \(status)", category: "UsageQuotaService")
                return ProviderUsageQuota(
                    provider: .codex,
                    status: .valid,
                    fetchedAt: now,
                    errorMessage: "HTTP \(status)"
                )
            }
            let parsed = try UsageQuotaParser.parseCodexQuota(data: data, fetchedAt: now)
            LogService.info("Codex quota fetched: \(parsed.tiers.count) tiers", category: "UsageQuotaService")
            return parsed
        } catch {
            LogService.error("Codex quota fetch failed: \(error.localizedDescription)", category: "UsageQuotaService")
            return ProviderUsageQuota(
                provider: .codex,
                status: .valid,
                fetchedAt: now,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func readCodexCredential() -> UsageCredential {
        // File first — see readClaudeCredential for the rationale (avoids the prompt).
        if FileManager.default.fileExists(atPath: codexAuthURL.path) {
            do {
                let data = try Data(contentsOf: codexAuthURL)
                return try UsageCredentialParser.parseCodexCredentials(data: data)
            } catch {
                LogService.warn(
                    "Codex credential file unreadable, trying Keychain: \(error.localizedDescription)",
                    category: "UsageQuotaService"
                )
            }
        }
        // No usable file — resolve from the Keychain without ever prompting here.
        return readKeychainCredential(provider: .codex, service: codexKeychainService) {
            try? UsageCredentialParser.parseCodexCredentials(data: $0)
        }
    }

    /// Keychain-only credential resolution that NEVER prompts on this (automatic)
    /// path. The legacy login-keychain ACL guards the *secret data*: a GUI app
    /// reading another app's `kSecReturnData` triggers the consent dialog, and
    /// `applyNoUI` does NOT suppress it (it only gates LocalAuthentication UI).
    /// So:
    /// - If the user authorized before (`keychainGranted`), attempt the silent
    ///   no-UI data read — instant for "Always Allow" (we're in the ACL). If that
    ///   fails the grant is gone, so forget it and fall through to the button.
    /// - Otherwise only probe *attributes* (never prompts): item present →
    ///   `.needsAuthorization` (render the Authorize button, NO data read here);
    ///   absent → `.notFound`.
    private func readKeychainCredential(
        provider: QuotaProvider,
        service: String,
        parse: (Data) -> UsageCredential?
    ) -> UsageCredential {
        if keychainGranted(provider) {
            let (data, status) = keychainBlob(service: service)
            if let data, let credential = parse(data) {
                return credential
            }
            // Only forget the grant when the item is genuinely gone. A transient
            // failure — e.g. errSecInteractionNotAllowed after the ad-hoc signature's
            // ACL trust lapses across sleep — keeps the grant so a later refresh can
            // retry the silent read instead of forcing a manual re-authorize.
            if status == errSecItemNotFound {
                LogService.warn(
                    "Keychain item for \(provider.rawValue) gone; forgetting grant",
                    category: "UsageQuotaService"
                )
                setKeychainGranted(false, provider)
            } else {
                LogService.warn(
                    "Keychain read for \(provider.rawValue) failed transiently (OSStatus \(status)); keeping grant",
                    category: "UsageQuotaService"
                )
            }
        }
        let probe = keychainProbe(service: service)
        LogService.info(
            "Keychain probe \(provider.rawValue): \(probe) (granted=\(keychainGranted(provider)))",
            category: "UsageQuotaService"
        )
        switch probe {
        case .authorized, .needsAuthorization:
            return UsageCredential(token: nil, status: .needsAuthorization)
        case .notFound, .failure:
            return UsageCredential(token: nil, status: .notFound)
        }
    }

    private func codexCredentialPresent() -> Bool {
        if FileManager.default.fileExists(atPath: codexAuthURL.path) { return true }
        // An unauthorized-but-present item still counts as present, so the Codex
        // section shows (and offers the Authorize button) instead of hiding.
        switch keychainProbe(service: codexKeychainService) {
        case .authorized, .needsAuthorization: return true
        case .notFound, .failure: return false
        }
    }

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
            LogService.error(
                "Gemini quota: credential unreadable: \(error.localizedDescription)",
                category: "UsageQuotaService"
            )
            return ProviderUsageQuota(
                provider: .gemini,
                status: .notFound,
                fetchedAt: now,
                errorMessage: error.localizedDescription
            )
        }
        guard credential.status != .parseError else {
            return ProviderUsageQuota(
                provider: .gemini,
                status: .parseError,
                fetchedAt: now,
                errorMessage: credential.message
            )
        }

        guard let accessToken = await resolveGeminiAccessToken(credential) else {
            return ProviderUsageQuota(
                provider: .gemini,
                status: .expired,
                fetchedAt: now,
                errorMessage: "Re-login required"
            )
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
                LogService.warn("Gemini quota: HTTP 401", category: "UsageQuotaService")
                return ProviderUsageQuota(
                    provider: .gemini,
                    status: .expired,
                    fetchedAt: now,
                    errorMessage: "Re-login required"
                )
            }
            guard (200 ..< 300).contains(status) else {
                LogService.error("Gemini quota: HTTP \(status)", category: "UsageQuotaService")
                return ProviderUsageQuota(
                    provider: .gemini,
                    status: .valid,
                    fetchedAt: now,
                    errorMessage: "HTTP \(status)"
                )
            }
            let parsed = try UsageQuotaParser.parseGeminiQuota(data: data, fetchedAt: now)
            LogService.info("Gemini quota fetched: \(parsed.tiers.count) tiers", category: "UsageQuotaService")
            return parsed
        } catch {
            LogService.error("Gemini quota fetch failed: \(error.localizedDescription)", category: "UsageQuotaService")
            return ProviderUsageQuota(
                provider: .gemini,
                status: .valid,
                fetchedAt: now,
                errorMessage: error.localizedDescription
            )
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
        guard let client = await Task.detached { GeminiOAuthClientLocator.resolve() }.value else {
            LogService.error("Gemini quota: OAuth client credentials not found", category: "UsageQuotaService")
            return nil
        }
        var request = URLRequest(url: geminiTokenRefreshURL, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id=\(Self.formEncode(client.clientId))",
            "client_secret=\(Self.formEncode(client.clientSecret))",
            "refresh_token=\(Self.formEncode(refreshToken))",
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
        do {
            let updated = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
            try updated.write(to: geminiCredentialsURL, options: .atomic)
        } catch {
            LogService.warn(
                "Gemini token write-back failed: \(error.localizedDescription)",
                category: "UsageQuotaService"
            )
        }
    }

    /// Percent-encodes a value for an `application/x-www-form-urlencoded` body
    /// using the RFC3986 unreserved set (encodes `/`, `+`, `=`, `&`, etc.).
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
           let project = extractProjectID(from: json) {
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
                if let labels = project["labels"] as? [String: String],
                   labels["generative-language"] != nil { return id }
            }
        }

        LogService.warn("Gemini project unresolved; sending empty quota body", category: "UsageQuotaService")
        return nil
    }

    private func extractProjectID(from json: [String: Any]) -> String? {
        if let s = json["cloudaicompanionProject"] as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let obj = json["cloudaicompanionProject"] as? [String: Any] {
            return (obj["id"] as? String) ?? (obj["projectId"] as? String)
        }
        return nil
    }

    // MARK: - Keychain

    /// Reads a CLI's credential blob, stored as a Keychain generic-password
    /// item keyed by service name (the account is the macOS username and
    /// varies), so we match on `kSecAttrService` alone and take one result.
    /// The query is forced non-interactive (`applyNoUI`): these items belong to
    /// the Claude/Codex CLIs, so reading them from NemoNotch would otherwise pop
    /// the macOS "wants to use confidential information" dialog. Instead the
    /// lookup returns `errSecInteractionNotAllowed` (→ nil) and we fall back to
    /// the on-disk credential file.
    private func keychainBlob(service: String) -> (data: Data?, status: OSStatus) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        applyNoUI(to: &query)
        // Belt-and-suspenders for the legacy login keychain: the per-query no-UI
        // flags above do NOT suppress its ACL confirmation dialog on a data read,
        // so an untrusted `kSecReturnData` read would pop the consent dialog even
        // on this automatic path. Disabling process-wide interaction makes such a
        // read fail with errSecInteractionNotAllowed instead — the caller then
        // forgets the (stale) grant and falls back to the Authorize button rather
        // than surprising the user with a prompt. A genuinely trusted read needs
        // no interaction, so it still succeeds silently.
        let toggle = Self.setUserInteractionAllowed
        _ = toggle?(false)
        defer { _ = toggle?(true) }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (nil, status) }
        return (result as? Data, status)
    }

    private enum KeychainProbe { case authorized, needsAuthorization, notFound, failure }

    /// Non-interactive existence/authorization probe. Requests attributes only
    /// (never `kSecReturnData` — asking for the secret can itself surface the
    /// legacy prompt) so we can tell "exists but unauthorized" from "absent"
    /// without ever prompting.
    private func keychainProbe(service: String) -> KeychainProbe {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        applyNoUI(to: &query)
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return .authorized
        case errSecInteractionNotAllowed: return .needsAuthorization
        case errSecItemNotFound: return .notFound
        default: return .failure
        }
    }

    /// User-initiated grant: performs ONE *interactive* Keychain read, surfacing
    /// the macOS consent dialog. On success the quota is refreshed (subsequent
    /// non-interactive reads then succeed silently); on denial nothing changes.
    func authorize(_ provider: QuotaProvider) async {
        guard provider != .gemini else {
            LogService.warn(
                "Quota authorize ignored: Gemini uses file-based OAuth, not Keychain",
                category: "UsageQuotaService"
            )
            return
        }
        let service = keychainService(for: provider)
        LogService.info("Quota authorize requested: \(provider.rawValue)", category: "UsageQuotaService")
        // SecItemCopyMatching blocks while the dialog is up — run it off the main
        // actor so the UI doesn't freeze.
        let granted = await Task.detached { Self.interactiveKeychainRead(service: service) != nil }.value
        if granted {
            LogService.info("Quota authorize granted: \(provider.rawValue)", category: "UsageQuotaService")
            setKeychainGranted(true, provider)
            await refresh(force: true)
        } else {
            LogService.warn("Quota authorize denied or failed: \(provider.rawValue)", category: "UsageQuotaService")
        }
    }

    /// Whether the user has authorized Keychain access for this provider *for the
    /// currently-running code identity*. The grant is keyed by cdhash, not a bare
    /// bool: macOS binds "Always Allow" ACL trust to the code signature, and
    /// ad-hoc signing changes that every rebuild. Comparing cdhash means a stale
    /// grant (from an older build) reads as NOT granted, so the entry path shows
    /// the Authorize button instead of doing a data read that would prompt.
    private func keychainGranted(_ provider: QuotaProvider) -> Bool {
        guard let current = Self.currentCodeIdentity() else { return false }
        return UserDefaults.standard.string(forKey: grantedIdentityKey(provider)) == current
    }

    private func setKeychainGranted(_ granted: Bool, _ provider: QuotaProvider) {
        if granted, let current = Self.currentCodeIdentity() {
            UserDefaults.standard.set(current, forKey: grantedIdentityKey(provider))
        } else {
            UserDefaults.standard.removeObject(forKey: grantedIdentityKey(provider))
        }
    }

    private func grantedIdentityKey(_ provider: QuotaProvider) -> String {
        "quota.keychainGrantedIdentity.\(provider.rawValue)"
    }

    /// The running code's cdhash, hex-encoded — the identity the Keychain ACL
    /// trusts. Returns nil if it can't be resolved, in which case `keychainGranted`
    /// is false (safe: show the button, never auto-read).
    private nonisolated static func currentCodeIdentity() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let cdhash = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return cdhash.map { String(format: "%02x", $0) }.joined()
    }

    private func keychainService(for provider: QuotaProvider) -> String {
        switch provider {
        case .claude: claudeKeychainService
        case .codex: codexKeychainService
        case .gemini: "" // Gemini uses file-based OAuth, not Keychain
        }
    }

    /// Interactive read — deliberately omits `applyNoUI`, so macOS shows the
    /// consent dialog when access hasn't been granted. Used only from `authorize`.
    private nonisolated static func interactiveKeychainRead(service: String) -> Data? {
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

    /// Makes a Keychain query strictly non-interactive. `LAContext.interactionNotAllowed`
    /// covers the data-protection keychain; `kSecUseAuthenticationUIFail` is still
    /// needed for the legacy login keychain, where these CLI credentials actually
    /// live. The deprecated constant is resolved at runtime via `dlsym` so we keep
    /// its true value without a compile-time reference to the deprecated symbol.
    /// (Pattern borrowed from CodexBar's `KeychainNoUIQuery`.)
    private func applyNoUI(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = Self.uiFailPolicy as CFString
    }

    /// Runtime-resolved `SecKeychainSetUserInteractionAllowed(_:)` — the legacy
    /// keychain's process-wide interaction toggle. Unlike the per-query no-UI
    /// flags (which only gate the data-protection keychain / LAContext), this is
    /// what actually turns the login keychain's ACL data-read dialog into an
    /// `errSecInteractionNotAllowed` failure. Resolved via `dlsym` so there's no
    /// compile-time reference to the deprecated symbol; nil (no-op) if unresolved.
    /// `Boolean` (C `unsigned char`) bridges to `DarwinBoolean`.
    private static let setUserInteractionAllowed: (@convention(c) (DarwinBoolean) -> OSStatus)? = {
        let path = "/System/Library/Frameworks/Security.framework/Security"
        // Intentionally keep the handle open for the process lifetime — the
        // returned function pointer must stay valid.
        guard let handle = dlopen(path, RTLD_NOW),
              let symbol = dlsym(handle, "SecKeychainSetUserInteractionAllowed") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (DarwinBoolean) -> OSStatus).self)
    }()

    /// Runtime-resolved value of `kSecUseAuthenticationUIFail`. Falls back to the
    /// known literal ("u_AuthUIF") if the symbol can't be loaded.
    private static let uiFailPolicy: String = {
        let path = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(path, RTLD_NOW) else { return "u_AuthUIF" }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else { return "u_AuthUIF" }
        let pointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (pointer.pointee as String?) ?? "u_AuthUIF"
    }()
}
