import Foundation

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
}
