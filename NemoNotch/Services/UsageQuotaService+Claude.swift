import Darwin
import Foundation
import LocalAuthentication
import Security

extension UsageQuotaService {
    // MARK: - Claude

    func fetchClaude() async -> ProviderUsageQuota {
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

    func readClaudeCredential(now: Date) -> UsageCredential {
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
                if credential.status == .valid {
                    writeClaudeCache(from: data)
                }
                return credential
            } catch {
                LogService.warn(
                    "Claude credential file unreadable, trying Keychain: \(error.localizedDescription)",
                    category: "UsageQuotaService"
                )
            }
        }
        // No usable cache or file — resolve from the Keychain. Two interchangeable
        // paths: the `/usr/bin/security` CLI (silent for the ACL-less Claude item,
        // never prompts) or the Security-framework read (may need authorization).
        let parse: (Data) -> UsageCredential? = { data in
            let credential = try? UsageCredentialParser.parseClaudeCredentials(data: data, now: now)
            if credential?.status == .valid {
                self.writeClaudeCache(from: data)
            }
            return credential
        }
        if useSecurityCLIForClaudeKeychain {
            return readKeychainCredentialViaSecurityCLI(
                service: claudeKeychainService,
                parse: parse
            )
        }
        return readKeychainCredential(provider: .claude, service: claudeKeychainService, parse: parse)
    }

    /// Writes a minimal copy of the Claude credential — accessToken + expiresAt
    /// only, deliberately NOT the refreshToken — to ~/.NemoNotch/claude-cred.json
    /// with 0600 permissions. This read cache lets refreshes avoid the Keychain
    /// (see `readClaudeCredential`); it is a plaintext copy of a secret, so it
    /// stores the least it can and is locked to the owner.
    func writeClaudeCache(from raw: Data) {
        guard
            let root = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
            let entry = (root["claudeAiOauth"] ?? root["claude.ai_oauth"]) as? [String: Any],
            let token = entry["accessToken"] as? String, !token.isEmpty
        else { return }
        var minimal: [String: Any] = ["accessToken": token]
        if let expiresAt = entry["expiresAt"] {
            minimal["expiresAt"] = expiresAt
        }
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
    func invalidateClaudeCache() {
        guard FileManager.default.fileExists(atPath: claudeCacheURL.path) else { return }
        try? FileManager.default.removeItem(at: claudeCacheURL)
        LogService.info("Claude credential cache invalidated (401)", category: "UsageQuotaService")
    }
}
