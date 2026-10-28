import Foundation

extension UsageQuotaService {
    // MARK: - Claude

    func fetchClaude() async -> ProviderUsageQuota {
        let now = Date()
        let quota: ProviderUsageQuota
        if !FileManager.default.fileExists(atPath: claudeSnapshotURL.path) {
            quota = ClaudeUsageSnapshotParser.parse(data: nil, now: now)
        } else {
            do {
                let data = try Data(contentsOf: claudeSnapshotURL)
                quota = ClaudeUsageSnapshotParser.parse(data: data, now: now)
            } catch {
                // Present but unreadable (permissions/IO) is distinct from "not
                // configured": surface the reason instead of a configure hint.
                LogService.warn(
                    "Claude quota snapshot unreadable: \(error.localizedDescription)",
                    category: "UsageQuotaService"
                )
                quota = ProviderUsageQuota(
                    provider: .claude,
                    status: .parseError,
                    fetchedAt: now,
                    errorMessage: "Snapshot unreadable: \(error.localizedDescription)"
                )
            }
        }
        logClaudeQuotaState(quota)
        return quota
    }

    private func logClaudeQuotaState(_ quota: ProviderUsageQuota) {
        let state = "\(quota.status) tiers=\(quota.tiers.count)"
        if state != lastClaudeQuotaLogState {
            LogService.info("Claude quota snapshot: \(state)", category: "UsageQuotaService")
            lastClaudeQuotaLogState = state
        } else {
            LogService.debug("Claude quota snapshot unchanged: \(state)", category: "UsageQuotaService")
        }
    }
}
