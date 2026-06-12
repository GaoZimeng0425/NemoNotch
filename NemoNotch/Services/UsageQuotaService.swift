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
        // File first — most users have ~/.claude/.credentials.json, so the common
        // path never touches the Keychain (and never triggers its cross-app prompt).
        if FileManager.default.fileExists(atPath: claudeCredentialsURL.path) {
            do {
                let data = try Data(contentsOf: claudeCredentialsURL)
                return try UsageCredentialParser.parseClaudeCredentials(data: data, now: now)
            } catch {
                LogService.warn(
                    "Claude credential file unreadable, trying Keychain: \(error.localizedDescription)",
                    category: "UsageQuotaService"
                )
            }
        }
        // No usable file — resolve from the Keychain without ever prompting here.
        return readKeychainCredential(provider: .claude, service: claudeKeychainService) {
            try? UsageCredentialParser.parseClaudeCredentials(data: $0, now: now)
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
            if let data = keychainBlob(service: service), let credential = parse(data) {
                return credential
            }
            LogService.warn(
                "Keychain grant for \(provider.rawValue) no longer valid; reverting to Authorize",
                category: "UsageQuotaService"
            )
            setKeychainGranted(false, provider)
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

    // MARK: - Keychain

    /// Reads a CLI's credential blob, stored as a Keychain generic-password
    /// item keyed by service name (the account is the macOS username and
    /// varies), so we match on `kSecAttrService` alone and take one result.
    /// The query is forced non-interactive (`applyNoUI`): these items belong to
    /// the Claude/Codex CLIs, so reading them from NemoNotch would otherwise pop
    /// the macOS "wants to use confidential information" dialog. Instead the
    /// lookup returns `errSecInteractionNotAllowed` (→ nil) and we fall back to
    /// the on-disk credential file.
    private func keychainBlob(service: String) -> Data? {
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
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
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
