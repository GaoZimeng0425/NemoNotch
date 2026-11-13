import Foundation

@MainActor
@Observable
final class AICLIMonitorService {
    let store: AISessionStore
    let claudeProvider: ClaudeProvider
    let geminiProvider: GeminiProvider
    let opencodeProvider: OpencodeProvider
    let zcodeProvider: ZcodeProvider
    let hookServer: HookServer
    weak var hermesService: HermesService?

    var serverRunning = false

    /// Per-source monitoring gate (the Settings toggle). Injectable so tests
    /// can gate without touching the shared UserDefaults domain.
    var sourceGate: (AISource) -> Bool = { AICLIMonitorService.monitoringEnabled(for: $0) }

    /// The toggle is the single service-layer gate: disabled sources get no
    /// events routed, no discovery polling, no hooks re-installed. Absent keys
    /// default to on — a fresh install behaves like before the toggle existed.
    static func monitoringEnabled(for source: AISource) -> Bool {
        let key: String = switch source {
        case .claude: AppSettings.claudeEnabledKey
        case .gemini: AppSettings.geminiEnabledKey
        case .opencode: AppSettings.opencodeEnabledKey
        case .zcode: AppSettings.zcodeEnabledKey
        }
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// Hermes is not an `AIProvider` (its agents live outside the session
    /// store) — its toggle reads the same UserDefaults shape.
    var hermesGate: () -> Bool = {
        UserDefaults.standard.object(forKey: AppSettings.hermesEnabledKey) as? Bool ?? true
    }

    init() {
        let store = AISessionStore()
        let claude = ClaudeProvider(store: store)
        let gemini = GeminiProvider(store: store)
        let opencode = OpencodeProvider(store: store)
        let zcode = ZcodeProvider(store: store)
        self.store = store
        claudeProvider = claude
        geminiProvider = gemini
        opencodeProvider = opencode
        zcodeProvider = zcode
        hookServer = HookServer()

        claude.setHookServer(hookServer)
        gemini.setHookServer(hookServer)
        opencode.setHookServer(hookServer)
        zcode.setHookServer(hookServer)

        // Refresh hook-sender.sh on launch when hooks are installed, so socket
        // path / script version migrations take effect without requiring the
        // user to click Reinstall in Settings.
        if UITestMode.ownsSharedHookConfig,
           claude.isHookInstalled || gemini.isHookInstalled || opencode.isHookInstalled || zcode.isHookInstalled {
            do {
                try HookInstaller.ensureScriptExists()
                // 令牌头是脚本模板的一部分:发送方必须与服务器同步刷新,否则
                // 升级后的服务器会 401 拒掉旧脚本的事件。
                if HermesHookInstaller.isInstalled {
                    try? HermesHookInstaller.refreshScript()
                }
                try? OpencodePluginInstaller.refreshScript()
            } catch {
                LogService.warn("Failed to refresh hook script: \(error)", category: "AICLIMonitorService")
            }
        }

        hookServer.onEventReceived = { [weak self] event in
            self?.routeEvent(event)
        }
        hookServer.onReady = { [weak self] in
            self?.handleServerReady()
        }
    }

    func startServer() {
        hookServer.start()
    }

    /// The disk scans and Claude's session-record polling. Not in `init`:
    /// tests build bare instances, and only the app's one instance may scan
    /// transcripts and poll records forever. Only `AppDependencies.build()`
    /// calls this. Disabled sources discover nothing — the toggle gates the
    /// whole pipeline, not just the badge.
    func startSessionDiscovery() {
        if sourceGate(.claude) {
            claudeProvider.scanExistingSessions()
        }
        if sourceGate(.gemini) {
            geminiProvider.scanExistingSessions()
        }
    }

    /// Toggle-flip entry point: the ONE call the Settings card makes. Off =
    /// uninstall hooks, stop discovery/watchers, silently clear the source's
    /// sessions (no `sessionLost` edge). On = install hooks, resume discovery.
    /// `completionFlash` is wired by `AppDependencies.build()`.
    weak var completionFlash: CompletionFlashService?

    /// Hermes toggle — same contract as `setMonitoring`, but agents live in
    /// the registry view, not the session store: forget them before they
    /// leave, or their disappearance reads as `sessionLost`.
    func setHermesMonitoring(enabled: Bool) {
        guard let hermes = hermesService else { return }
        if enabled {
            hermes.installHooks()
            hermes.connect()
        } else {
            completionFlash?.forgetAgentKeys(Set(hermes.agents.keys.map { "agent:" + $0 }))
            hermes.disconnect()
            hermes.uninstallHooks()
            hermes.agents.removeAll()
        }
    }

    func setMonitoring(enabled: Bool, for source: AISource) {
        switch source {
        case .claude:
            if enabled {
                claudeProvider.installHooks()
                claudeProvider.scanExistingSessions()
            } else {
                claudeProvider.uninstallHooks()
                claudeProvider.stopDiscovery()
            }
        case .gemini:
            if enabled {
                geminiProvider.installHooks()
                geminiProvider.scanExistingSessions()
            } else {
                geminiProvider.uninstallHooks()
                geminiProvider.stopDiscovery()
            }
        case .opencode:
            if enabled {
                opencodeProvider.installHooks()
            } else {
                opencodeProvider.uninstallHooks()
            }
        case .zcode:
            if enabled {
                zcodeProvider.installHooks()
            } else {
                zcodeProvider.uninstallHooks()
            }
        }
        if !enabled {
            completionFlash?.forgetSessions(for: source)
        }
    }

    var activeSession: AISessionState? {
        store.activeSession
    }

    var anyHookInstalled: Bool {
        claudeProvider.isHookInstalled || geminiProvider.isHookInstalled
            || opencodeProvider.isHookInstalled || zcodeProvider.isHookInstalled
    }

    func respondToPermission(sessionId: String, approved: Bool) {
        guard let session = store.get(sessionId) else { return }
        switch session.source {
        case .claude: claudeProvider.respondToPermission(sessionId: sessionId, approved: approved)
        case .gemini: geminiProvider.respondToPermission(sessionId: sessionId, approved: approved)
        case .opencode: opencodeProvider.respondToPermission(sessionId: sessionId, approved: approved)
        case .zcode: zcodeProvider.respondToPermission(sessionId: sessionId, approved: approved)
        }
    }

    /// A multi-choice ask answered from the bar. Only Claude's PermissionRequest
    /// protocol carries an answer; any other source is left to its own terminal.
    func respondToAsk(sessionId: String, answers: [String: String]) {
        guard let session = store.get(sessionId),
              case let .waitingForApproval(ctx) = session.phase else { return }
        switch session.source {
        case .claude:
            claudeProvider.respondToAsk(
                sessionId: sessionId, originalInput: ctx.toolInput ?? "{}", answers: answers
            )
        case .gemini, .opencode, .zcode:
            LogService.info(
                "Ask answer not supported for \(session.source.rawValue); answer in its terminal",
                category: "AICLIMonitorService"
            )
        }
    }

    // MARK: - Event Routing

    private func routeEvent(_ event: HookEvent) {
        var source = event.cliSource ?? "unknown"
        LogService.debug(
            "Incoming event: \(event.hookEventName), raw source: \(event.cliSource ?? "nil"), session: \(event.sessionId ?? "nil")",
            category: "AICLIMonitorService"
        )

        if source == "unknown" {
            // opencode session ids are `ses_…`, zcode's are `sess_…` — distinct
            // prefixes. A foreign untagged emitter (e.g. another opencode plugin)
            // can race ahead of our tagged event, so attribute by id format
            // before the Claude fallback creates a `.claude` phantom.
            if event.sessionId?.hasPrefix("sess_") == true {
                source = "zcode"
            } else if event.sessionId?.hasPrefix("ses_") == true {
                source = "opencode"
            } else {
                let combined = "\(event.message ?? "") \(event.toolName ?? "") \(event.cwd ?? "")".lowercased()
                if combined.contains("gemini") || combined.contains("glm") {
                    source = "gemini"
                }
            }
        }

        // Resolve the final target first, then gate: a disabled source must see
        // no events at all — tagged, prefix-attributed, or the untagged Claude
        // fallback. The old UI-only filter left these paths alive, so sessions
        // kept coming back after "uninstall".
        if source == "hermes" {
            if hermesGate() {
                LogService.info("Routing event \(event.hookEventName) to hermes", category: "AICLIMonitorService")
                hermesService?.handleHookEvent(event)
            } else {
                LogService.info(
                    "Routing event \(event.hookEventName) to hermes — disabled, dropped",
                    category: "AICLIMonitorService"
                )
                return
            }
        } else {
            let target: AISource = switch source {
            case "gemini": .gemini
            case "claude": .claude
            case "opencode": .opencode
            case "zcode": .zcode
            default:
                // Final fallback: route by which provider owns the session,
                // else Claude — the fallback inherits the claude gate.
                store.get(event.sessionId ?? "")?.source ?? .claude
            }
            guard sourceGate(target) else {
                LogService.info(
                    "Routing event \(event.hookEventName) to \(source) — disabled, dropped",
                    category: "AICLIMonitorService"
                )
                return
            }
            LogService.info("Routing event \(event.hookEventName) to \(source)", category: "AICLIMonitorService")

            switch target {
            case .claude: claudeProvider.handleEvent(event)
            case .gemini: geminiProvider.handleEvent(event)
            case .opencode: opencodeProvider.handleEvent(event)
            case .zcode: zcodeProvider.handleEvent(event)
            }
        }

        // Record the hosting terminal/IDE for session jumps (FAB "open in
        // terminal"). After dispatch so the session exists; no-op when the
        // event carries no pid (plugin-based emitters like opencode) or the
        // walk finds no GUI ancestor (tmux/ssh).
        if let cliPID = event.cliPID, let sessionId = event.sessionId {
            store.mutate(sessionId) { session in
                AppActivator.recordHost(cliPID: Int32(cliPID), on: &session)
            }
        }
    }

    private func handleServerReady() {
        serverRunning = true
        // The heal pass installs hooks only for enabled sources — this used
        // to resurrect an uninstalled claude/gemini hook on every launch.
        // Status flags still reflect the on-disk truth either way.
        if sourceGate(.claude) {
            try? HookInstaller.install(.claude)
        }
        if sourceGate(.gemini) {
            try? HookInstaller.install(.gemini)
        }
        claudeProvider.isHookInstalled = HookInstaller.isInstalled(.claude)
        geminiProvider.isHookInstalled = HookInstaller.isInstalled(.gemini)
        if sourceGate(.opencode) {
            try? OpencodePluginInstaller.install()
        }
        opencodeProvider.isHookInstalled = OpencodePluginInstaller.isInstalled
        if sourceGate(.zcode), FileManager.default.fileExists(atPath: HookTarget.zcode.settingsPath) {
            try? HookInstaller.install(.zcode)
        }
        zcodeProvider.isHookInstalled = HookInstaller.isInstalled(.zcode)
    }
}
