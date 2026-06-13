import SwiftUI

/// Watches the AI session store and agent registry for work-completion edges
/// (working→idle / active→idle) and drives the full-screen edge glow + toast.
/// Throttles: the first completion flashes and shows a toast; completions
/// arriving during the cooldown merge their names into the visible toast
/// without replaying the flash.
@MainActor
@Observable
final class CompletionFlashService {
    /// Drives the edge-glow level, 0...1 (scaled by `completionGlowOpacity` in
    /// the view). Animated through the double-pulse curve inside `withAnimation`.
    private(set) var flashLevel: Double = 0
    /// Project/agent names shown in the current toast.
    private(set) var toastNames: [String] = []
    /// Whether the toast is currently shown.
    private(set) var toastVisible = false

    private let store: AISessionStore
    private let registry: AgentMonitorRegistry
    private let settings: AppSettings

    private var detector = CompletionDetector()
    private var inCooldown = false
    private var cooldownTask: Task<Void, Never>?
    private var flashResetTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?

    init(store: AISessionStore, registry: AgentMonitorRegistry, settings: AppSettings) {
        self.store = store
        self.registry = registry
        self.settings = settings
        LogService.info("CompletionFlashService init", category: "CompletionFlash")
        // Prime the detector so units already active at launch don't flash.
        _ = detector.step(currentCandidates())
        observe()
    }

    deinit {
        MainActor.assumeIsolated {
            cooldownTask?.cancel()
            flashResetTask?.cancel()
            toastDismissTask?.cancel()
            LogService.info("CompletionFlashService deinit", category: "CompletionFlash")
        }
    }

    // MARK: - Snapshot

    private func currentCandidates() -> [CompletionCandidate] {
        var result: [CompletionCandidate] = []
        for session in store.sortedSessions {
            result.append(CompletionCandidate(
                key: "ai:\(session.id)",
                name: session.projectFolder ?? session.displayTitle,
                // Active == .working only; a session merely .waiting is not "working".
                isActive: session.status == .working
            ))
        }
        for monitor in registry.installedMonitors {
            for agent in monitor.agents.values {
                result.append(CompletionCandidate(
                    key: "agent:\(agent.id)",
                    name: agent.name,
                    isActive: agent.state != .idle
                ))
            }
        }
        return result
    }

    // MARK: - Observation

    private func observe() {
        withObservationTracking {
            // Touch the tracked state so onChange fires on any mutation.
            _ = store.sortedSessions.map { ($0.id, $0.status) }
            for monitor in registry.installedMonitors {
                _ = monitor.agents.mapValues { $0.state }
            }
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                observe() // re-arm before evaluating so no change is missed
                evaluate()
            }
        }
    }

    private func evaluate() {
        let completed = detector.step(currentCandidates())
        guard !completed.isEmpty else { return }
        guard settings.completionFlashEnabled else {
            LogService.debug("Completion ignored — flash disabled", category: "CompletionFlash")
            return
        }
        LogService.debug("Completion detected: \(completed)", category: "CompletionFlash")
        handle(names: completed)
    }

    // MARK: - UI test

    /// Screenshot helper: pin the glow at full level and show a toast with the
    /// given names, with no auto-reset/cooldown. Only used under `--uitest --flash`.
    func holdForUITest(names: [String]) {
        flashLevel = 1
        toastNames = names
        toastVisible = true
        LogService.debug("Flash held for UI test: \(names)", category: "CompletionFlash")
    }

    // MARK: - Throttle / merge

    private func handle(names: [String]) {
        if inCooldown {
            toastNames = CompletionFlashNames.merge(existing: toastNames, new: names)
            restartToastDismiss()
            LogService.debug("Merged into active toast: \(toastNames)", category: "CompletionFlash")
        } else {
            triggerFlash()
            toastNames = CompletionFlashNames.merge(existing: [], new: names)
            showToast()
            startCooldown()
        }
    }

    private func triggerFlash() {
        LogService.debug("Flash triggered", category: "CompletionFlash")
        flashResetTask?.cancel()
        flashResetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Continuous double-pulse: 0 → 1 → dipLevel → 1 → 0.
            // easeInOut throughout keeps every transition soft at both ends.
            withAnimation(.easeInOut(duration: NotchConstants.completionFlashRise)) {
                self.flashLevel = 1
            }
            try? await Task.sleep(for: .seconds(NotchConstants.completionFlashRise))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: NotchConstants.completionFlashDip)) {
                self.flashLevel = NotchConstants.completionFlashDipLevel
            }
            try? await Task.sleep(for: .seconds(NotchConstants.completionFlashDip))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: NotchConstants.completionFlashRise)) {
                self.flashLevel = 1
            }
            try? await Task.sleep(for: .seconds(NotchConstants.completionFlashRise))
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: NotchConstants.completionFlashFall)) {
                self.flashLevel = 0
            }
        }
    }

    private func showToast() {
        toastVisible = true
        restartToastDismiss()
    }

    private func restartToastDismiss() {
        toastDismissTask?.cancel()
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NotchConstants.completionToastDuration))
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: NotchConstants.hudDismissDuration)) {
                self.toastVisible = false
            }
        }
    }

    private func startCooldown() {
        inCooldown = true
        cooldownTask?.cancel()
        cooldownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(NotchConstants.completionFlashThrottle))
            guard let self, !Task.isCancelled else { return }
            inCooldown = false
        }
    }
}
