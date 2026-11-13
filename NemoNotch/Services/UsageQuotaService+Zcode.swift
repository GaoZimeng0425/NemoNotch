import Darwin
import Foundation
import LocalAuthentication
import Security

extension UsageQuotaService {
    // MARK: - zcode (BigModel coding-plan quota + local usage stats)

    func fetchZcodeQuotaIfPresent() async -> ProviderUsageQuota? {
        guard FileManager.default.fileExists(atPath: ZcodeCredentials.credentialsURL.path) else { return nil }
        hasZcodeCredential = true
        let keyResult = zcodeKeyringKey()
        let apiKeyIsV2 = ZcodeCredentials.apiKeyEntry(
            in: ZcodeCredentials.credentialsDict() ?? [:]
        )?.value.hasPrefix("enc:v2:") == true
        if case .needsAuthorization = keyResult, apiKeyIsV2 {
            // Item present, ACL not ours yet: the Authorize button (user
            // action) is the only door to an interactive read — never prompt
            // from this automatic timer.
            logQuotaStateTransition("keyring key needs authorization")
            return ProviderUsageQuota(provider: .zcode, status: .needsAuthorization, fetchedAt: Date())
        }
        guard let token = zcodeBearerToken(keyResult: keyResult) else {
            // The API key is v2-encrypted and the keyring key is missing/unreadable
            // (CLI not logged in on this keychain, or access denied). Silent by
            // design — this is an automatic timer, never a prompt. Return a
            // state object: nil would make refresh() drop the .zcode entry and
            // the card would sit on "reading" forever.
            logQuotaStateTransition("credential undecryptable (v2 key unavailable)")
            return ProviderUsageQuota(
                provider: .zcode, status: .expired, fetchedAt: Date(),
                errorMessage: "v2 key unavailable"
            )
        }
        var request = URLRequest(url: zcodeQuotaURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logQuotaStateTransition("HTTP \(http.statusCode)")
                return ProviderUsageQuota(
                    provider: .zcode, status: .parseError, fetchedAt: Date(),
                    errorMessage: "HTTP \(http.statusCode)"
                )
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
            logQuotaStateTransition("network: \(error.localizedDescription)")
            return ProviderUsageQuota(
                provider: .zcode, status: .parseError, fetchedAt: Date(),
                errorMessage: error.localizedDescription
            )
        }
    }

    /// Bearer token for the quota API: the coding-plan API key (enc:v2:os,
    /// key from the CLI's keyring entry) first, the legacy plaintext oauth
    /// access token as a fallback for pre-v2 CLI installs.
    /// nil only when the state is surfaced separately by the caller.
    private func zcodeBearerToken(keyResult: ZcodeKeyringKeyResult) -> String? {
        guard let dict = ZcodeCredentials.credentialsDict() else { return nil }
        if let entry = ZcodeCredentials.apiKeyEntry(in: dict) {
            if entry.value.hasPrefix("enc:v2:") {
                guard case let .key(key) = keyResult else { return nil }
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
    /// Outcome of trying to obtain the CLI's credential-encryption key.
    enum ZcodeKeyringKeyResult: Equatable {
        case key(Data)
        /// Item present but this app isn't in its ACL yet — render the
        /// Authorize button (Codex's `.needsAuthorization` contract).
        case needsAuthorization
        /// Item absent — the CLI isn't logged in on this machine.
        case unavailable
    }

    /// The CLI's credential-encryption key from the login keychain, following
    /// Codex's grant pattern: a stored (cdhash-gated) grant unlocks the silent
    /// data read; without it only an attributes probe runs — never a prompt.
    /// Transient silent-read failures keep the grant (ACL trust can lapse
    /// across sleep); only a genuinely vanished item forgets it.
    private func zcodeKeyringKey() -> ZcodeKeyringKeyResult {
        let service = keychainService(for: .zcode)
        let account = ZcodeCredentials.keyringAccount()
        if keychainGranted(.zcode) {
            let (data, status) = keychainBlob(service: service, account: account)
            if let b64 = data.flatMap({ String(data: $0, encoding: .utf8) }),
               let key = Self.decodeKeyringKey(b64) {
                return .key(key)
            }
            if status == errSecItemNotFound {
                setKeychainGranted(false, .zcode)
            } else {
                LogService.warn(
                    "zcode keyring read failed transiently (OSStatus \(status)); keeping grant",
                    category: "UsageQuotaService"
                )
            }
        }
        switch keychainProbe(service: service, account: account) {
        case .authorized, .needsAuthorization:
            return .needsAuthorization
        case .notFound, .failure:
            return .unavailable
        }
    }

    /// 43-char base64url → 32 raw bytes (the CLI stores the key verbatim).
    static func decodeKeyringKey(_ b64: String) -> Data? {
        let padded = b64
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .padding(toLength: 44, withPad: "=", startingAt: 0)
        guard let key = Data(base64Encoded: padded), key.count == 32 else { return nil }
        return key
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
