import SwiftUI

/// Watches the AI session store and agent registry for work-completion edges
/// (working→idle / active→idle) and drives the full-screen edge glow + the
/// toast row under the notch. Throttles the glow only: the first completion
/// flashes, completions arriving during the cooldown don't replay it. Every
/// completion gets its own toast card (`CompletionToastQueue`).
@MainActor
@Observable
final class CompletionFlashService {
    /// Drives the edge-glow level, 0...1 (scaled by `completionGlowOpacity` in
    /// the view). Animated through the double-pulse curve inside `withAnimation`.
    private(set) var flashLevel: Double = 0
    /// The toast cards under the notch, oldest first.
    private(set) var toasts: [CompletionToast] = []

    /// Whether the full-screen glow windows need to be on screen.
    ///
    /// Deliberately falls **later** than `flashLevel`: that is assigned
    /// instantly while its interpolation (`completionFlashFall`) still has to
    /// run. Ordering the window out on the assignment would cut the fade off.
    private(set) var overlayVisible = false

    private let store: AISessionStore
    private let registry: AgentMonitorRegistry
    private let settings: AppSettings

    private var detector = CompletionDetector()
    private var inCooldown = false
    private var cooldownTask: Task<Void, Never>?
    private var flashResetTask: Task<Void, Never>?
    private var toastExpiryTask: Task<Void, Never>?
    private var toastQueue = CompletionToastQueue(
        duration: NotchConstants.completionToastDuration,
        capacity: NotchConstants.completionToastCapacity
    )

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
            toastExpiryTask?.cancel()
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
                duration: Date().timeIntervalSince(session.sessionStart),
                path: session.cwd,
                jump: CompletionJump.make(
                    hostPID: session.launchingAppPID,
                    hostBundleId: session.launchingAppBundleId,
                    tabLink: session.tabLinkURL
                )
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

    // MARK: - External flash

    /// Fire the full-screen edge glow + toast from an external trigger
    /// (calendar event due, Bluetooth audio device connect/disconnect).
    /// Goes through the same throttle/merge pipeline as AI/agent completions:
    /// inside the cooldown window the items merge into the visible toast
    /// instead of replaying the flash.
    func showCompletionFlash(items: [CompletionItem]) {
        guard settings.completionFlashEnabled else {
            LogService.debug("External flash ignored — completion flash disabled", category: "CompletionFlash")
            return
        }
        guard !items.isEmpty else { return }
        LogService.debug("External flash triggered: \(items.map(\.name))", category: "CompletionFlash")
        handle(items: items)
    }

    // MARK: - External toast (no flash)

    /// Show completion toasts without firing the full-screen edge glow — used
    /// by the Pomodoro end alert, whose visual channel is the notch ring pulse
    /// rather than the glow. Deliberately leaves the flash cooldown untouched
    /// so it can never swallow a subsequent AI/agent flash.
    func showCompletionToast(names: [String]) {
        guard settings.completionFlashEnabled else {
            LogService.debug("Completion toast ignored — completion flash disabled", category: "CompletionFlash")
            return
        }
        addToasts(names.map { CompletionItem(name: $0, source: .pomodoro) })
        LogService.debug("Completion toast shown (no flash): \(names)", category: "CompletionFlash")
    }

    // MARK: - Toast row interaction

    /// The close button on one card.
    func dismissToast(id: UUID) {
        toastQueue.dismiss(id: id)
        syncToasts()
        LogService.debug("Toast dismissed by user", category: "CompletionFlash")
    }

    /// Pointer over the toast row: freeze every card's timer. Leaving restarts
    /// them from full so a card being read never vanishes as the cursor leaves.
    func setToastHover(_ hovering: Bool) {
        guard hovering != toastQueue.isPaused else { return }
        if hovering {
            toastQueue.pause()
        } else {
            toastQueue.resume(now: Date())
        }
        syncToasts()
    }

    // MARK: - UI test

    /// Screenshot helper: pin the glow at full level and show a toast with the
    /// given names, with no auto-reset/cooldown. Only used under `--uitest --flash`.
    func holdForUITest(names: [String]) {
        flashLevel = 1
        // Show a Claude-sourced item so the screenshot demonstrates the source logo.
        toastQueue.add(names.map { name in
            var item = CompletionItem(name: name, source: .ai(.claude))
            item.path = NSHomeDirectory() + "/Documents/Learn/macos/" + name
            return item
        }, now: Date())
        // Screenshot mode never decays: a paused queue expires nothing.
        toastQueue.pause()
        syncToasts()
        // No reset task will ever lower the glow, so the overlay stays up.
        overlayVisible = true
        LogService.debug("Flash held for UI test: \(names)", category: "CompletionFlash")
    }

    // MARK: - Throttle / merge

    private func handle(items: [CompletionItem]) {
        if inCooldown {
            LogService.debug("Flash throttled, toast only: \(items.map(\.name))", category: "CompletionFlash")
        } else {
            triggerFlash()
            startCooldown()
        }
        addToasts(items)
    }

    private func triggerFlash() {
        LogService.debug("Flash triggered", category: "CompletionFlash")
        flashResetTask?.cancel()
        overlayVisible = true
        flashResetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Continuous double-pulse: 0 → 1 → dipLevel → 1 → 0.
            // easeInOut throughout keeps every transition soft at both ends.
            withAnimation(.easeInOut(duration: NotchConstants.completionFlashRise)) {
                self.flashLevel = 1
            }
            try? await Task.sleep(for: .seconds(NotchConstants.completionFlashRise))
            if Task.isCancelled {
                return
            }
            withAnimation(.easeInOut(duration: NotchConstants.completionFlashDip)) {
                self.flashLevel = NotchConstants.completionFlashDipLevel
            }
            try? await Task.sleep(for: .seconds(NotchConstants.completionFlashDip))
            if Task.isCancelled {
                return
            }
            withAnimation(.easeInOut(duration: NotchConstants.completionFlashRise)) {
                self.flashLevel = 1
            }
            try? await Task.sleep(for: .seconds(NotchConstants.completionFlashRise))
            if Task.isCancelled {
                return
            }
            withAnimation(.easeInOut(duration: NotchConstants.completionFlashFall)) {
                self.flashLevel = 0
            }
            // Wait out the fade before letting the window leave the screen.
            try? await Task.sleep(for: .seconds(NotchConstants.completionFlashFall))
            if Task.isCancelled {
                return
            }
            overlayVisible = false
        }
    }

    private func addToasts(_ items: [CompletionItem]) {
        toastQueue.add(items, now: Date())
        syncToasts()
    }

    /// Publishes the queue and re-arms the single expiry timer for the
    /// earliest deadline (none while paused or empty).
    private func syncToasts() {
        if toasts != toastQueue.toasts {
            withAnimation(.spring(duration: NotchConstants.hudAppearDuration, bounce: 0.08)) {
                toasts = toastQueue.toasts
            }
        }
        toastExpiryTask?.cancel()
        guard let deadline = toastQueue.nextDeadline else { return }
        toastExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
            guard let self, !Task.isCancelled else { return }
            toastQueue.expire(now: Date())
            syncToasts()
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
