import Darwin
import Foundation
import LocalAuthentication
import Security

extension UsageQuotaService {
    // MARK: - Codex

    func fetchCodexIfPresent() async -> ProviderUsageQuota? {
        guard hasCodexCredential else { return nil }
        return await fetchCodex()
    }

    func fetchCodex() async -> ProviderUsageQuota {
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

    func readCodexCredential() -> UsageCredential {
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

    /// Keychain-only credential resolution via the `/usr/bin/security` CLI. This
    /// is the same path Claude Usage (and other third-party apps) take: shelling
    /// out to `/usr/bin/security find-generic-password -s <service> -w` returns
    /// the plaintext blob for the ACL-less `Claude Code-credentials` item without
    /// ever surfacing the macOS consent dialog — the CLI is an Apple-signed binary
    /// running in the user session, so it reads the login keychain silently. The
    /// `-w` (with password) flag is the read; failure (item absent / unreadable)
    /// maps to `.notFound`. `parse` turns the blob into a credential the same way
    /// the Security-framework path does, and writes the local cache on success.
    @discardableResult
    func readKeychainCredentialViaSecurityCLI(
        service: String,
        parse: (Data) -> UsageCredential?
    ) -> UsageCredential {
        guard let data = Self.securityCLICredentialBlob(service: service) else {
            LogService.info(
                "security CLI: no Claude keychain blob (not found or unreadable)",
                category: "UsageQuotaService"
            )
            return UsageCredential(token: nil, status: .notFound, message: "Claude keychain item not found")
        }
        if let credential = parse(data) {
            return credential
        }
        return UsageCredential(token: nil, status: .parseError, message: "Claude keychain blob unparseable")
    }

    /// Runs `/usr/bin/security find-generic-password -s <service> -w` and returns
    /// its stdout as `Data` (the CLI prints the plaintext keychain blob there).
    /// Returns nil on any non-zero exit or missing binary — callers treat that as
    /// "no credential". `execve`-style (no shell) so the service name is a real
    /// argv element, never a shell-injection vector.
    private nonisolated static func securityCLICredentialBlob(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        // The CLI prints the plaintext + a trailing newline; trim it.
        guard let text = String(data: data, encoding: .utf8) else { return data }
        return Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
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
    func readKeychainCredential(
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

    func codexCredentialPresent() -> Bool {
        if FileManager.default.fileExists(atPath: codexAuthURL.path) {
            return true
        }
        // An unauthorized-but-present item still counts as present, so the Codex
        // section shows (and offers the Authorize button) instead of hiding.
        switch keychainProbe(service: codexKeychainService) {
        case .authorized, .needsAuthorization: return true
        case .notFound, .failure: return false
        }
    }
}
