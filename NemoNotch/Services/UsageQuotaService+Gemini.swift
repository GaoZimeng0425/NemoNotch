import Darwin
import Foundation
import LocalAuthentication
import Security

extension UsageQuotaService {
    // MARK: - Gemini

    func geminiCredentialPresent() -> Bool {
        guard FileManager.default.fileExists(atPath: geminiCredentialsURL.path) else { return false }
        switch geminiAuthType() {
        case .apiKey, .vertexAI: return false
        case .oauthPersonal, .unknown: return true
        }
    }

    func geminiAuthType() -> GeminiAuthType {
        guard let data = try? Data(contentsOf: geminiSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let security = json["security"] as? [String: Any],
              let auth = security["auth"] as? [String: Any],
              let selected = auth["selectedType"] as? String else { return .unknown }
        return GeminiAuthType(rawValue: selected) ?? .unknown
    }

    func fetchGeminiIfPresent() async -> ProviderUsageQuota? {
        guard hasGeminiCredential else { return nil }
        return await fetchGemini()
    }

    func fetchGemini() async -> ProviderUsageQuota {
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
    func resolveGeminiAccessToken(_ credential: GeminiOAuthCredential) async -> String? {
        let expired = credential.expiryDate.map { $0 < Date() } ?? true
        if let token = credential.accessToken, !expired {
            return token
        }
        guard let refresh = credential.refreshToken, !refresh.isEmpty else {
            LogService.warn("Gemini quota: token expired, no refresh token", category: "UsageQuotaService")
            return nil
        }
        return await refreshGeminiToken(refreshToken: refresh)
    }

    func refreshGeminiToken(refreshToken: String) async -> String? {
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
    func writeBackGeminiToken(refreshResponse: [String: Any]) {
        guard let existing = try? Data(contentsOf: geminiCredentialsURL),
              var json = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] else { return }
        if let access = refreshResponse["access_token"] {
            json["access_token"] = access
        }
        if let expiresIn = refreshResponse["expires_in"] as? Double {
            json["expiry_date"] = (Date().timeIntervalSince1970 + expiresIn) * 1000
        }
        if let idToken = refreshResponse["id_token"] {
            json["id_token"] = idToken
        }
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
    func resolveGeminiProject(accessToken: String) async -> String? {
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
                if id.hasPrefix("gen-lang-client") {
                    return id
                }
                if let labels = project["labels"] as? [String: String],
                   labels["generative-language"] != nil {
                    return id
                }
            }
        }

        LogService.warn("Gemini project unresolved; sending empty quota body", category: "UsageQuotaService")
        return nil
    }

    func extractProjectID(from json: [String: Any]) -> String? {
        if let s = json["cloudaicompanionProject"] as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let obj = json["cloudaicompanionProject"] as? [String: Any] {
            return (obj["id"] as? String) ?? (obj["projectId"] as? String)
        }
        return nil
    }
}
