import Foundation

/// Edge-bar cards when a quota window passes the user's threshold (and when
/// it recovers), held until acknowledged. The decisions are the pure
/// `QuotaAlertDetector` / `QuotaAlerts` folds; this class only observes the
/// quota service + settings and owns the pending list.
///
/// `UsageQuotaService.setActive` is a view lifecycle hook (polls only while
/// the AI tab is visible), so the monitor runs its own timer at
/// `usageQuota.refreshInterval` and calls `refresh(force: false)` — the
/// service's 60s throttle de-duplicates against other callers. It never
/// touches `setActive` (a view disappearing would kill a shared timer).
@MainActor
@Observable
final class QuotaAlertMonitor {
    /// Not yet acknowledged, oldest first.
    private(set) var alerts: [QuotaAlert] = []

    /// On while the alerts and the edge bar (their only surface) are on.
    var isActive: Bool {
        appSettings.quotaAlertEnabled && appSettings.aiStatusFabEnabled
    }

    private let usageQuota: UsageQuotaService
    private let appSettings: AppSettings
    /// Windows currently counted as over the threshold.
    private var above: Set<QuotaAlertKey> = []
    /// The threshold the `above` set was last evaluated against; a change
    /// restarts detection (a raised threshold must not emit "recovered").
    private var lastThreshold: Int?
    private var timer: Timer?
    private var started = false

    init(usageQuota: UsageQuotaService, appSettings: AppSettings) {
        self.usageQuota = usageQuota
        self.appSettings = appSettings
        LogService.info("QuotaAlertMonitor init", category: "QuotaAlert")
    }

    deinit { MainActor.assumeIsolated { timer?.invalidate() } }

    func start() {
        guard !started else { return }
        started = true
        guard !UITestMode.isActive, !UITestMode.isTestHost else { return }
        // evaluate() first so syncPolling boots the timer even if nothing
        // tracked changes for a while; observe() re-runs it on every change.
        evaluate()
        observe()
    }

    /// Re-armable observation, mirroring WaitingReminderMonitor.observe():
    /// re-arm BEFORE acting so a change during evaluation isn't lost.
    private func observe() {
        withObservationTracking {
            _ = usageQuota.quotas
            _ = appSettings.quotaAlertEnabled
            _ = appSettings.aiStatusFabEnabled
            _ = appSettings.quotaAlertThreshold
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observe()
                self?.evaluate()
            }
        }
    }

    func acknowledge(_ id: String) {
        alerts = QuotaAlerts.acknowledging(id, in: alerts)
        LogService.info("Acknowledged alert \(id)", category: "QuotaAlert")
    }

    private func evaluate() {
        syncPolling(active: isActive)
        guard isActive else {
            if !alerts.isEmpty || !above.isEmpty {
                alerts = []
                above = []
                LogService.info("Cleared state: alerts or edge bar off", category: "QuotaAlert")
            }
            lastThreshold = nil
            return
        }
        if lastThreshold != appSettings.quotaAlertThreshold {
            // Restart detection: what is over the new threshold fires as an
            // arrival; a merely moved bar never fires a bogus "recovered".
            if !alerts.isEmpty || !above.isEmpty {
                alerts = []
                above = []
                LogService.info(
                    "Cleared state: threshold changed to \(appSettings.quotaAlertThreshold)",
                    category: "QuotaAlert"
                )
            }
            lastThreshold = appSettings.quotaAlertThreshold
        }
        let threshold = Double(appSettings.quotaAlertThreshold)
        let outcome = QuotaAlertDetector.plan(
            readings: QuotaAlertDetector.readings(from: usageQuota.quotas),
            above: above,
            threshold: threshold
        )
        above = outcome.above
        guard !outcome.events.isEmpty else { return }
        alerts = QuotaAlerts.apply(outcome.events, to: alerts, threshold: threshold, now: Date())
        for event in outcome.events {
            let reading: QuotaReading
            let kind: QuotaAlert.Kind
            switch event {
            case let .exceeded(r):
                reading = r
                kind = .exceeded
            case let .recovered(r):
                reading = r
                kind = .recovered
            }
            LogService.info(
                "Alert \(reading.key.id) \(kind.rawValue) at \(Int(reading.utilization.rounded()))%",
                category: "QuotaAlert"
            )
        }
    }

    /// Own polling while active — the quota service's own timer follows view
    /// lifecycle (`setActive`), which says nothing about the alert feature.
    private func syncPolling(active: Bool) {
        if active {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: usageQuota.refreshInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.usageQuota.refresh(force: false) }
            }
            timer.tolerance = 30
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            Task { await usageQuota.refresh(force: false) }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }
}
