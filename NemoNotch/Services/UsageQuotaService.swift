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
            guard (200 ..< 300).contains(status) else {
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
