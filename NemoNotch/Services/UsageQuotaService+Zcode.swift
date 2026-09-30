import Darwin
import Foundation
import LocalAuthentication
import Security

extension UsageQuotaService {
    // MARK: - zcode (BigModel coding-plan quota + local usage stats)

    func fetchZcodeQuotaIfPresent() async -> ProviderUsageQuota? {
        guard FileManager.default.fileExists(atPath: ZcodeCredentials.credentialsURL.path) else { return nil }
        hasZcodeCredential = true
        guard let token = ZcodeCredentials.accessToken() else {
            LogService.warn("zcode quota: credential undecryptable", category: "UsageQuotaService")
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
            guard let parsed = ZcodeQuotaParser.parse(data: data, fetchedAt: Date()) else {
                LogService.warn("zcode quota: parse failed", category: "UsageQuotaService")
                return nil
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
