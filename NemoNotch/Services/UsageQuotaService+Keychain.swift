import Darwin
import Foundation
import LocalAuthentication
import Security

extension UsageQuotaService {
    // MARK: - Keychain

    /// Reads a CLI's credential blob, stored as a Keychain generic-password
    /// item keyed by service name (the account is the macOS username and
    /// varies), so we match on `kSecAttrService` alone and take one result.
    /// The query is forced non-interactive (`applyNoUI`): these items belong to
    /// the Claude/Codex CLIs, so reading them from NemoNotch would otherwise pop
    /// the macOS "wants to use confidential information" dialog. Instead the
    /// lookup returns `errSecInteractionNotAllowed` (→ nil) and we fall back to
    /// the on-disk credential file.
    func keychainBlob(service: String) -> (data: Data?, status: OSStatus) {
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

    enum KeychainProbe { case authorized, needsAuthorization, notFound, failure }

    /// Non-interactive existence/authorization probe. Requests attributes only
    /// (never `kSecReturnData` — asking for the secret can itself surface the
    /// legacy prompt) so we can tell "exists but unauthorized" from "absent"
    /// without ever prompting.
    func keychainProbe(service: String) -> KeychainProbe {
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
    func keychainGranted(_ provider: QuotaProvider) -> Bool {
        guard let current = Self.currentCodeIdentity() else { return false }
        return UserDefaults.standard.string(forKey: grantedIdentityKey(provider)) == current
    }

    func setKeychainGranted(_ granted: Bool, _ provider: QuotaProvider) {
        if granted, let current = Self.currentCodeIdentity() {
            UserDefaults.standard.set(current, forKey: grantedIdentityKey(provider))
        } else {
            UserDefaults.standard.removeObject(forKey: grantedIdentityKey(provider))
        }
    }

    func grantedIdentityKey(_ provider: QuotaProvider) -> String {
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

    func keychainService(for provider: QuotaProvider) -> String {
        switch provider {
        case .claude: claudeKeychainService
        case .codex: codexKeychainService
        case .gemini: "" // Gemini uses file-based OAuth, not Keychain
        case .zcode: "" // zcode credentials are locally encrypted, never Keychain
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
    func applyNoUI(to query: inout [String: Any]) {
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
