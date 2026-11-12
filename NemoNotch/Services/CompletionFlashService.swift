import SwiftUI

/// Watches the AI session store and agent registry for active→inactive
/// edges (each completion carries its `ReminderKind` — done, or lost) and
/// for arrivals into "parked on the user" (attention cards), and drives the
/// tone-colored full-screen edge glow + the toast row under the notch.
/// Throttles the glow only: the first batch flashes, arrivals during the
/// cooldown don't replay it. Every completion gets its own toast card
/// (`CompletionToastQueue`).
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

    /// Why a card left the row on its own terms. A card pushed off-row to wait
    /// (or dropped from a full waiting pile) is deliberately not reported —
    /// the user may never have seen it.
    enum ToastRemoval {
        case dismissed // close button, or a click that jumped/opened then closed it
        case expired
    }

    /// Called after a card is dismissed or expires (not when it waits off-row).
    var onToastRemoved: ((CompletionItem, ToastRemoval) -> Void)?

    private let store: AISessionStore
    private let registry: AgentMonitorRegistry
    private let settings: AppSettings

    private var detector = CompletionDetector()
    private var attentionDetector = AttentionDetector()
    /// The previous snapshot of `hitApiError` flags — a false→true flip after
    /// the turn's Stop is the "late apiError" (transcript parsed post-Stop).
    private var priorApiError: [String: Bool] = [:]
    /// The tone the current glow runs in (spec: colors encode why the user
    /// is needed). Same-batch arbitration picks the highest-priority tone.
    private(set) var glowTone: ReminderTone = .green
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
        // Prime the detectors so units already active — or already parked on
        // the user, or already error-flagged by record discovery — don't fire
        // at launch: baseline, not news.
        let baseline = currentCandidates()
        _ = detector.step(baseline)
        _ = attentionDetector.step(baseline.map { ($0.key, $0.attentionKind) })
        priorApiError = Dictionary(
            uniqueKeysWithValues: store.sortedSessions.map { ($0.id, $0.hitApiError) }
        )
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
        var result = store.sortedSessions.map { ReminderSnapshot.aiCandidate($0) }
        for monitor in registry.installedMonitors {
            for agent in monitor.agents.values {
                result.append(
                    ReminderSnapshot.agentCandidate(id: agent.id, name: agent.name, state: agent.state)
                )
            }
        }
        return result
    }

    // MARK: - Observation

    private func observe() {
        let armProbe = PerfProbe.begin()
        withObservationTracking {
            // Touch the tracked state so onChange fires on any mutation.
            _ = store.sortedSessions.map { ($0.id, $0.status, $0.phase) }
            _ = store.sortedSessions.map { ($0.id, $0.hitApiError) }
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
        let candidates = currentCandidates()
        let completed = detector.step(candidates)
        let attention = attentionDetector.step(
            candidates.map { ($0.key, $0.attentionKind) }
        )

        // 1) The CLI parked on the user: sticky cards that leave with their
        //    wait (answered / bridge timeout / answered in terminal). The
        //    arrival also flashes the glow in its tone — being blocked on
        //    the user outranks being done (spec 语义表).
        for (key, kind) in attention.arrived where settings.attentionToastEnabled {
            if let item = askItem(candidateKey: key, kind: kind) {
                LogService.debug(
                    "Attention arrived: \(kind) for \(String(key.dropFirst(3)).prefix(8))",
                    category: "CompletionFlash"
                )
                addToasts([item])
                flashIfNeeded(kind.tone)
            }
        }
        for key in attention.retracted {
            let toastKey = "ask:" + String(key.dropFirst("ai:".count))
            if toastQueue.replace(key: toastKey, with: nil, now: Date()) {
                LogService.debug("Attention card retracted: \(toastKey)", category: "CompletionFlash")
                syncToasts()
            }
        }

        // 2) Completions and failures, each in its tone.
        if !completed.isEmpty {
            LogService.debug(
                "Completion detected: \(completed.map(\.name)) [\(completed.map { $0.kind.map { "\($0)" } ?? "-" }.joined(separator: ","))]",
                category: "CompletionFlash"
            )
            handle(completed)
        }

        // 3) A late apiError mark — the transcript's evidence parsed after
        //    the Stop already showed the green card. Swap it for the red one.
        let apiFlags = Dictionary(
            uniqueKeysWithValues: store.sortedSessions.map { ($0.id, $0.hitApiError) }
        )
        for (id, flagged) in apiFlags where flagged && priorApiError[id] != true {
            emitLateFailure(sessionID: id)
        }
        priorApiError = apiFlags
    }

    /// The sticky card for an arrival into "parked on the user": its face is
    /// the question being asked (AskUserQuestion summary) or the tool line
    /// awaiting the click.
    private func askItem(candidateKey: String, kind: ReminderKind) -> CompletionItem? {
        let sessionID = String(candidateKey.dropFirst("ai:".count))
        guard let session = store.get(sessionID) else { return nil }
        var face: String?
        if case let .waitingForApproval(ctx) = session.phase {
            face = ctx.interactivePrompt?.summary
                ?? (ctx.displayInput.isEmpty ? nil : ctx.displayInput)
        }
        var item = CompletionItem(
            name: session.projectFolder ?? session.displayTitle,
            source: .ai(session.source),
            subtitle: face ?? session.lastUserMessage ?? session.displayTitle,
            tool: session.currentTool,
            model: session.displayModel,
            tokenDisplay: nil,
            duration: nil,
            path: session.cwd,
            jump: CompletionJump.make(
                hostPID: session.launchingAppPID,
                hostBundleId: session.launchingAppBundleId,
                tabLink: session.tabLinkURL
            )
        )
        item.key = "ask:\(sessionID)"
        item.kind = kind
        item.sticky = true
        return item
    }

    /// The transcript's API-error mark arrived after the turn's Stop: the
    /// green card was the best knowledge at the time — now it is a lie.
    /// Show the red card and displace the same session's green one
    /// (spec 审计口径 3).
    private func emitLateFailure(sessionID: String) {
        guard settings.failureToastEnabled, let session = store.get(sessionID) else { return }
        var item = CompletionItem(
            name: session.projectFolder ?? session.displayTitle,
            source: .ai(session.source),
            subtitle: session.lastUserMessage ?? session.displayTitle,
            tool: nil,
            model: session.displayModel,
            tokenDisplay: session.tokenDisplay,
            duration: nil,
            path: session.cwd,
            jump: CompletionJump.make(
                hostPID: session.launchingAppPID,
                hostBundleId: session.launchingAppBundleId,
                tabLink: session.tabLinkURL
            )
        )
        item.key = "fail:\(sessionID)"
        item.kind = .apiError
        LogService.info(
            "Late apiError card for session \(sessionID.prefix(8))",
            category: "CompletionFlash"
        )
        addToasts([item])
        toastQueue.demote(sessionKey: sessionID, keeping: "fail:\(sessionID)", now: Date())
        syncToasts()
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
        handle(items)
    }

    // MARK: - Notification Center cards

    /// A notification card with new arrivals: shown (or refreshed with a full
    /// timer) without the edge glow and without touching the flash throttle.
    /// Not gated on `completionFlashEnabled` — `NotificationToastService`
    /// owns this feature's switch.
    func showNotificationToast(_ item: CompletionItem) {
        addToasts([item])
        LogService.debug("Notification toast shown: \(item.toastKey)", category: "CompletionFlash")
    }

    /// A notification card whose content changed with nothing new arriving
    /// (records left Notification Center): updated in place, timer kept; nil
    /// removes it. No card under `key` → nothing happens.
    func updateNotificationToast(key: String, item: CompletionItem?) {
        guard toastQueue.replace(key: key, with: item, now: Date()) else { return }
        syncToasts()
    }

    // MARK: - External app cards (POST /v1/toast)

    /// An external-app push: shown (or refreshed with a full timer when the
    /// card key repeats) without the edge glow and without touching the flash
    /// throttle — the glow means "AI work finished", external sources don't
    /// get to trigger it. Not gated on `completionFlashEnabled`:
    /// `ExternalCardService` owns this feature's switch.
    func showExternalToast(_ item: CompletionItem) {
        addToasts([item])
        LogService.debug("External toast shown: \(item.toastKey)", category: "CompletionFlash")
    }

    /// An external `action: "close"`: removes the card keyed `key` from the row
    /// or the waiting pile (the next parked card refills a freed slot). No card
    /// under `key` → nothing happens.
    func closeExternalToast(key: String) {
        guard toastQueue.replace(key: key, with: nil, now: Date()) else { return }
        syncToasts()
        LogService.debug("External toast closed: \(key)", category: "CompletionFlash")
    }

    // MARK: - Toast row interaction

    /// The close button on one card.
    func dismissToast(id: UUID) {
        let item = toastQueue.toasts.first { $0.id == id }?.item
        toastQueue.dismiss(id: id, now: Date())
        syncToasts()
        LogService.debug("Toast dismissed by user", category: "CompletionFlash")
        if let item {
            onToastRemoved?(item, .dismissed)
        }
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
        // Cycle the four tones so one screenshot shows every ring color.
        let tones: [ReminderKind?] = [.turnDone, .needsDecision, .needsApproval, .sessionLost]
        toastQueue.add(names.enumerated().map { index, name in
            var item = CompletionItem(name: name, source: .ai(.claude))
            item.path = NSHomeDirectory() + "/Documents/Learn/macos/" + name
            item.kind = tones[index % tones.count]
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

    private func handle(_ items: [CompletionItem]) {
        // Switches gate the EMISSION, never the snapshot: filtering here
        // (not in currentCandidates) means flipping a switch on later cannot
        // replay edges the detector already consumed.
        let enabled = items.filter { toneAllowed($0.kind?.tone ?? .green) }
        guard !enabled.isEmpty else {
            LogService.debug(
                "All \(items.count) item(s) gated off by their tone switch",
                category: "CompletionFlash"
            )
            return
        }
        // Same-batch arbitration: rescue-red outranks decide-amber
        // outranks approve-blue outranks green. Inside the cooldown window
        // this is a no-op — the cards still go out below (spec 审计口径 5).
        if let winner = ReminderTone.pick(enabled.map { $0.kind?.tone ?? .green }) {
            flashIfNeeded(winner)
        }
        addToasts(enabled)
    }

    /// Flash the glow in `tone` unless the cooldown window is running.
    private func flashIfNeeded(_ tone: ReminderTone) {
        guard !inCooldown else {
            LogService.debug("Flash throttled, toast only: \(tone)", category: "CompletionFlash")
            return
        }
        glowTone = tone
        triggerFlash()
        startCooldown()
    }

    /// Tone→switch: green keeps the legacy completion switch (now green
    /// only); amber/blue answer to the attention switch, red to the failure
    /// switch — independent, no master gate (spec 审计口径 2).
    private func toneAllowed(_ tone: ReminderTone) -> Bool {
        switch tone {
        case .green: settings.completionFlashEnabled
        case .amber, .blue: settings.attentionToastEnabled
        case .red: settings.failureToastEnabled
        }
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
            let expired = toastQueue.expire(now: Date())
            syncToasts()
            for toast in expired {
                onToastRemoved?(toast.item, .expired)
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
