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
    /// Finished units (name + source logo) shown in the current toast.
    private(set) var toastItems: [CompletionItem] = []
    /// Whether the toast is currently shown.
    private(set) var toastVisible = false

    /// Whether the full-screen overlay windows need to be on screen.
    ///
    /// Deliberately falls **later** than `flashLevel` / `toastVisible`: those are
    /// assigned instantly while their visual interpolation still has to run
    /// (`completionFlashFall` for the glow, `hudDismissDuration` for the toast).
    /// Ordering the window out on the assignment would cut the animation off.
    private(set) var overlayVisible = false

    /// The two independent reasons the overlay may be needed. Tracked
    /// separately because a flash (~1.2s) and a toast (~5.2s) end at different
    /// times, and a merge can restart the toast while the flash is long done.
    private var flashHolding = false
    private var toastHolding = false

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
                isActive: session.status == .working,
                source: .ai(session.source),
                subtitle: session.displayTitle,
                tool: session.currentTool,
                model: session.displayModel,
                tokenDisplay: session.tokenDisplay,
                duration: Date().timeIntervalSince(session.sessionStart)
            ))
        }
        for monitor in registry.installedMonitors {
            for agent in monitor.agents.values {
                result.append(CompletionCandidate(
                    key: "agent:\(agent.id)",
                    name: agent.name,
                    isActive: agent.state != .idle,
                    source: .agent
                ))
            }
        }
        return result
    }

    // MARK: - Observation

    private func observe() {
        let armProbe = PerfProbe.begin()
        withObservationTracking {
            // Touch the tracked state so onChange fires on any mutation.
            _ = store.sortedSessions.map { ($0.id, $0.status) }
            for monitor in registry.installedMonitors {
                _ = monitor.agents.mapValues { $0.state }
            }
        } onChange: {
            // 若 evaluate() 又改动了被观察状态，这里会自激成死循环 ——
            // onChange 频率远高于真实事件频率就是证据。
            PerfProbe.hit("CompletionFlashService.observe.onChange")
            Task { @MainActor [weak self] in
                guard let self else { return }
                observe() // re-arm before evaluating so no change is missed
                let evalProbe = PerfProbe.begin()
                evaluate()
                PerfProbe.end("CompletionFlashService.evaluate", evalProbe)
            }
        }
        PerfProbe.end("CompletionFlashService.observe.arm(读取全部会话快照)", armProbe)
    }

    private func evaluate() {
        let completed = detector.step(currentCandidates())
        guard !completed.isEmpty else { return }
        guard settings.completionFlashEnabled else {
            LogService.debug("Completion ignored — flash disabled", category: "CompletionFlash")
            return
        }
        LogService.debug("Completion detected: \(completed.map(\.name))", category: "CompletionFlash")
        handle(items: completed)
    }

    // MARK: - External toast (no flash)

    /// Show the unified completion toast without firing the full-screen edge
    /// glow — used by the Pomodoro end alert, whose visual channel is the notch
    /// ring pulse rather than the glow. Merges into a visible toast if one is
    /// up. Deliberately leaves the flash cooldown untouched so it can never
    /// swallow a subsequent AI/agent flash.
    func showCompletionToast(names: [String]) {
        guard settings.completionFlashEnabled else {
            LogService.debug("Completion toast ignored — completion flash disabled", category: "CompletionFlash")
            return
        }
        let items = names.map { CompletionItem(name: $0, source: .pomodoro) }
        let base = toastVisible ? toastItems : []
        toastItems = CompletionFlashNames.merge(existing: base, new: items)
        showToast()
        LogService.debug("Completion toast shown (no flash): \(toastItems.map(\.name))", category: "CompletionFlash")
    }

    // MARK: - UI test

    /// Screenshot helper: pin the glow at full level and show a toast with the
    /// given names, with no auto-reset/cooldown. Only used under `--uitest --flash`.
    func holdForUITest(names: [String]) {
        flashLevel = 1
        // Show a Claude-sourced item so the screenshot demonstrates the source logo.
        toastItems = names.map { CompletionItem(name: $0, source: .ai(.claude)) }
        toastVisible = true
        // Screenshot mode never decays, so the overlay has to stay up: no
        // reset/dismiss task will ever lower these.
        flashHolding = true
        toastHolding = true
        syncOverlayVisibility()
        LogService.debug("Flash held for UI test: \(names)", category: "CompletionFlash")
    }

    // MARK: - Throttle / merge

    private func handle(items: [CompletionItem]) {
        if inCooldown {
            toastItems = CompletionFlashNames.merge(existing: toastItems, new: items)
            restartToastDismiss()
            LogService.debug("Merged into active toast: \(toastItems.map(\.name))", category: "CompletionFlash")
        } else {
            triggerFlash()
            toastItems = CompletionFlashNames.merge(existing: [], new: items)
            showToast()
            startCooldown()
        }
    }

    private func triggerFlash() {
        LogService.debug("Flash triggered", category: "CompletionFlash")
        flashResetTask?.cancel()
        flashHolding = true
        syncOverlayVisibility()
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
            // Wait out the fade before letting the window leave the screen.
            try? await Task.sleep(for: .seconds(NotchConstants.completionFlashFall))
            if Task.isCancelled { return }
            self.flashHolding = false
            self.syncOverlayVisibility()
        }
    }

    private func showToast() {
        toastVisible = true
        toastHolding = true
        syncOverlayVisibility()
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
            try? await Task.sleep(for: .seconds(NotchConstants.hudDismissDuration))
            if Task.isCancelled { return }
            self.toastHolding = false
            self.syncOverlayVisibility()
        }
    }

    private func syncOverlayVisibility() {
        let needed = flashHolding || toastHolding
        guard needed != overlayVisible else { return }
        overlayVisible = needed
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
