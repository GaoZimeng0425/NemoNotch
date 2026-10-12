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
    var quotas: [QuotaProvider: ProviderUsageQuota] = [:]
    var isRefreshing = false
    /// Whether a Codex credential exists (drives the Codex section's visibility).
    /// Computed at init so the UI gate is correct before the first fetch.
    var hasCodexCredential = false

    let claudeKeychainService = "Claude Code-credentials"
    /// When true, resolve the Claude OAuth token via the `/usr/bin/security` CLI
    /// (`find-generic-password -w`) instead of `SecItemCopyMatching`. The CLI runs
    /// as an Apple-signed binary in the user session, so it silently returns the
    /// plaintext for the ACL-less `Claude Code-credentials` item — no consent
    /// dialog and no `needsAuthorization` gate (this is how Claude Usage and
    /// similar apps read it). Flip to `false` to restore the Security-framework
    /// path; the two branches are otherwise interchangeable.
    let useSecurityCLIForClaudeKeychain = true
    let claudeCredentialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")
    /// Local read cache of the last good Claude token (accessToken + expiresAt only).
    /// Lets refreshes skip the Keychain entirely; see `readClaudeCredential`.
    let claudeCacheURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".NemoNotch/claude-cred.json")
    let claudeUsageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    let codexKeychainService = "Codex Auth"
    let codexAuthURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")
    let codexUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    let geminiCredentialsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/oauth_creds.json")
    let geminiSettingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/settings.json")
    let geminiTokenRefreshURL = URL(string: "https://oauth2.googleapis.com/token")!
    let geminiLoadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    let geminiQuotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    let geminiProjectsURL = URL(string: "https://cloudresourcemanager.googleapis.com/v1/projects")!

    /// Whether a usable Gemini OAuth credential exists (drives section visibility).
    var hasGeminiCredential = false

    /// zcode local usage stats (today / 7 days). nil until the first
    /// successful read; a failed read keeps the previous value. Fallback
    /// display when the quota API is unavailable (not logged in / fetch failed).
    var zcodeUsage: ZcodeUsageStats?
    let zcodeDatabaseURL = ZcodeUsageReader.defaultDatabaseURL
    /// Whether zcode's credential file decrypts (drives the ZCode quota
    /// section's visibility, like `hasCodexCredential`).
    var hasZcodeCredential = false
    let zcodeQuotaURL = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
    /// Cloud Code project id, resolved once per process run.
    var geminiProjectID: String?

    let throttleInterval: TimeInterval = 60
    let refreshInterval: TimeInterval = 300

    var timer: Timer?
    var lastFetched: Date?

    init() {
        LogService.info("UsageQuotaService init", category: "UsageQuotaService")
        hasCodexCredential = codexCredentialPresent()
        hasGeminiCredential = geminiCredentialPresent()
        hasZcodeCredential = FileManager.default.fileExists(atPath: ZcodeCredentials.credentialsURL.path)
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
        if isRefreshing {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        hasCodexCredential = codexCredentialPresent()
        hasGeminiCredential = geminiCredentialPresent()
        async let claudeTask = fetchClaude()
        async let codexTask = fetchCodexIfPresent()
        async let geminiTask = fetchGeminiIfPresent()
        async let zcodeTask = fetchZcodeUsageIfPresent()
        async let zcodeQuotaTask = fetchZcodeQuotaIfPresent()
        let (claudeResult, codexResult, geminiResult, zcodeResult, zcodeQuotaResult) =
            await (claudeTask, codexTask, geminiTask, zcodeTask, zcodeQuotaTask)
        if let zcodeResult {
            zcodeUsage = zcodeResult
        }

        var next: [QuotaProvider: ProviderUsageQuota] = [:]
        next[.claude] = backfilled(claudeResult, from: quotas[.claude])
        if let codexResult {
            next[.codex] = backfilled(codexResult, from: quotas[.codex])
        }
        if let geminiResult {
            next[.gemini] = backfilled(geminiResult, from: quotas[.gemini])
        }
        if let zcodeQuotaResult {
            next[.zcode] = backfilled(zcodeQuotaResult, from: quotas[.zcode])
        }
        quotas = next
        lastFetched = Date()
    }

    /// Re-applies a future reset time from the previous fetch to any fresh tier
    /// that came back without one.
    func backfilled(
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
}
