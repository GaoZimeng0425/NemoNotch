import Darwin
import Foundation
import LocalAuthentication
import Security

extension UsageQuotaService {
    // MARK: - Claude

    /// Claude quota source: the snapshot claude-hud mirrors out of Claude
    /// Code's statusline stdin. Deliberately credential-free and network-free —
    /// no token read, no usage API call. A missing snapshot reads as
    /// `.snapshotMissing`, one no session has refreshed within the fresh
    /// interval as `.snapshotStale` (old percentages are withheld).
    func fetchClaude() async -> ProviderUsageQuota {
        let now = Date()
        // ~200B file, atomically written by claude-hud — an inline read costs
        // less than hopping off the main actor for it.
        let data = try? Data(contentsOf: claudeSnapshotURL)
        let quota = ClaudeUsageSnapshotParser.parse(data: data, now: now)
        logClaudeQuotaState(quota)
        return quota
    }

    /// Logs the Claude quota result only when its state (status + tier count)
    /// changes; unchanged states log `.debug`. Prevents the 60s refresh loop
    /// from re-logging the same line every tick.
    private func logClaudeQuotaState(_ quota: ProviderUsageQuota) {
        let state = "\(quota.status) tiers=\(quota.tiers.count)"
        if state != lastClaudeQuotaLogState {
            LogService.info("Claude quota snapshot: \(state)", category: "UsageQuotaService")
            lastClaudeQuotaLogState = state
        } else {
            LogService.debug("Claude quota snapshot unchanged: \(state)", category: "UsageQuotaService")
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
