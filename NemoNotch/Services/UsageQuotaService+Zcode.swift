import Darwin
import Foundation
import LocalAuthentication
import Security

extension UsageQuotaService {
    // MARK: - zcode (BigModel coding-plan quota + local usage stats)

    func fetchZcodeQuotaIfPresent() async -> ProviderUsageQuota? {
        guard FileManager.default.fileExists(atPath: ZcodeCredentials.credentialsURL.path) else { return nil }
        hasZcodeCredential = true
        guard let token = zcodeBearerToken() else {
            // The API key is v2-encrypted and the keyring key is missing/unreadable
            // (CLI not logged in on this keychain, or access denied). Silent by
            // design — this is an automatic timer, never a prompt.
            logQuotaStateTransition("credential undecryptable (v2 key unavailable)")
            return nil
        }
        var request = URLRequest(url: zcodeQuotaURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                LogService.warn("zcode quota: HTTP \(http.statusCode)", category: "UsageQuotaService")
                return nil
            }
            // The API answers HTTP 200 with an envelope code: 401 means the
            // token is stale (the legacy oauth key is no longer refreshed by
            // the CLI). Surface that as a real state, not a parse failure.
            if let apiError = ZcodeQuotaParser.apiError(data: data) {
                logQuotaStateTransition("API \(apiError.code) \(apiError.msg)")
                return ProviderUsageQuota(
                    provider: .zcode, status: .expired, fetchedAt: Date(),
                    errorMessage: "API \(apiError.code) \(apiError.msg)"
                )
            }
            guard let parsed = ZcodeQuotaParser.parse(data: data, fetchedAt: Date()) else {
                logQuotaStateTransition("parse failed (unexpected payload shape)")
                return ProviderUsageQuota(provider: .zcode, status: .parseError, fetchedAt: Date())
            }
            LogService.info(
                "zcode quota fetched: \(parsed.tiers.map { "\($0.utilization)%" })",
                category: "UsageQuotaService"
            )
            return parsed
        } catch {
            LogService.warn(
                "zcode quota fetch failed: \(error.localizedDescription)",
                category: "UsageQuotaService"
            )
            return nil
        }
    }

    /// Bearer token for the quota API: the coding-plan API key (enc:v2:os,
    /// key from the CLI's keyring entry) first, the legacy plaintext oauth
    /// access token as a fallback for pre-v2 CLI installs.
    private func zcodeBearerToken() -> String? {
        guard let dict = ZcodeCredentials.credentialsDict() else { return nil }
        if let entry = ZcodeCredentials.apiKeyEntry(in: dict) {
            if entry.value.hasPrefix("enc:v2:") {
                guard let key = zcodeKeyringKey() else { return nil }
                return ZcodeCredentials.v2Decrypt(entry.value, key: key)
            }
            // Unexpected plaintext shape — use as-is.
            return entry.value
        }
        return ZcodeCredentials.accessToken()
    }

    /// The CLI's credential-encryption key from the login keychain. Account is
    /// the SHA256 hex of the credentials file path (how the CLI addresses its
    /// own entry). Reads are non-interactive: an ACL denial comes back as nil.
    private func zcodeKeyringKey() -> Data? {
        let account = ZcodeCredentials.keyringAccount()
        let (data, _) = keychainBlob(service: keychainService(for: .zcode), account: account)
        guard let b64 = data.flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        // 43-char base64url → 32 bytes.
        return Data(base64Encoded: b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            .padding(
                toLength: 44,
                withPad: "=",
                startingAt: 0
            ))
    }

    /// Logs quota failures only on state transition — the 60s/5min timers
    /// must not repeat the same line every tick (log-window discipline).
    private func logQuotaStateTransition(_ message: String) {
        guard lastZcodeQuotaLogState != message else { return }
        lastZcodeQuotaLogState = message
        LogService.warn("zcode quota: \(message)", category: "UsageQuotaService")
    }

    /// Reads the CLI's local sqlite off the main actor. A failed/locked read
    /// returns nil so the previous stats survive.
    func fetchZcodeUsageIfPresent() async -> ZcodeUsageStats? {
        guard FileManager.default.fileExists(atPath: zcodeDatabaseURL.path) else { return nil }
        let url = zcodeDatabaseURL
        let stats = await Task.detached(priority: .utility) {
            ZcodeUsageReader.read(databaseURL: url)
        }.value
        if stats == nil {
            LogService.warn("zcode usage read failed", category: "UsageQuotaService")
        } else {
            LogService.debug(
                "zcode usage read ok: today \(stats?.todayRequests ?? 0) req / \(stats?.todayTokens ?? 0) tok",
                category: "UsageQuotaService"
            )
        }
        return stats
    }
}
