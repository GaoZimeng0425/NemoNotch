import Foundation

@MainActor
@Observable
final class GeminiProvider: AIProvider {
    let source: AISource = .gemini
    var isHookInstalled = false

    private let store: AISessionStore
    private var timeoutTimer: Timer?
    private var sessionFiles: [String: String] = [:]
    private var fileMonitoredSessions: Set<String> = []
    private var fileMonitorTimer: Timer?
    private weak var hookServer: HookServer?

    init(store: AISessionStore) {
        self.store = store
        isHookInstalled = HookInstaller.isInstalled(.gemini)
    }

    func setHookServer(_ server: HookServer) {
        hookServer = server
    }

    func installHooks() {
        do {
            try HookInstaller.install(.gemini)
            isHookInstalled = true
        } catch {
            LogService.error("Failed to install Gemini hooks: \(error)", category: "GeminiProvider")
        }
    }

    func uninstallHooks() {
        do {
            try HookInstaller.uninstall(.gemini)
            isHookInstalled = false
        } catch {
            LogService.error("Failed to uninstall Gemini hooks: \(error)", category: "GeminiProvider")
        }
    }

    func respondToPermission(sessionId: String, approved: Bool) {
        hookServer?.respondToPermission(sessionId: sessionId, approved: approved)
        store.mutate(sessionId) { session in
            session.phase = session.phase.transition(to: .processing)
        }
    }

    // MARK: - Event Handling

    func handleEvent(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        let now = Date()

        // If we were file-monitoring this session, hooks have taken over
        if fileMonitoredSessions.remove(sessionId) != nil {
            if fileMonitoredSessions.isEmpty { stopFileMonitoring() }
        }

        switch event.hookEventName {
        case "SessionStart":
            var session = AISessionState(sessionId: sessionId, source: .gemini)
            session.phase = .idle
            applyContext(to: &session, event: event)
            if let cwd = event.cwd {
                sessionFiles[sessionId] = GeminiConversationParser.findSessionFile(sessionId: sessionId, cwd: cwd)
            }
            store.upsert(session)
            parseConversation(for: sessionId)

        case "BeforeAgent":
            store.mutateOrCreate(sessionId, source: .gemini) { session in
                session.phase = .processing
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
            }
            parseConversation(for: sessionId)

        case "BeforeTool":
            store.mutateOrCreate(sessionId, source: .gemini) { session in
                session.phase = .processing
                session.currentTool = event.toolName
                session.isPreToolUse = true
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
                if let toolName = event.toolName, toolName == "invoke_subagent" {
                    session.subagentState.startTask(
                        taskToolId: event.toolUseId ?? UUID().uuidString,
                        description: "Subagent"
                    )
                }
            }
            parseConversation(for: sessionId)

        case "AfterTool":
            store.mutateOrCreate(sessionId, source: .gemini) { session in
                session.currentTool = nil
                session.isPreToolUse = false
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
                if let toolName = event.toolName, toolName == "invoke_subagent" {
                    session.subagentState.stopTask(taskToolId: event.toolUseId ?? "")
                }
            }
            parseConversation(for: sessionId)

        case "Notification":
            store.mutateOrCreate(sessionId, source: .gemini) { session in
                session.phase = .waitingForInput
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
            }
            parseConversation(for: sessionId)

        case "AfterAgent":
            guard store.contains(sessionId) else { return }
            store.mutate(sessionId) { session in
                session.phase = .waitingForInput
                session.currentTool = nil
                session.isPreToolUse = false
                self.applyContext(to: &session, event: event)
                session.lastEventTime = now
            }
            parseConversation(for: sessionId)

        case "SessionEnd":
            sessionFiles.removeValue(forKey: sessionId)
            store.remove(sessionId)

        default:
            break
        }

        scheduleTimeoutCleanup()
    }

    // MARK: - Startup Scan

    func scanExistingSessions() {
        let projectsPath = NSHomeDirectory() + "/.gemini/projects.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: projectsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [String: String] else {
            return
        }

        let fm = FileManager.default
        let threshold = Date().addingTimeInterval(-3600)

        for (cwd, projectName) in projects {
            let chatsDir = NSHomeDirectory() + "/.gemini/tmp/\(projectName)/chats"
            guard let files = try? fm.contentsOfDirectory(atPath: chatsDir) else { continue }

            for file in files where file.hasSuffix(".json") {
                let filePath = chatsDir + "/" + file

                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let modDate = attrs[.modificationDate] as? Date,
                      modDate > threshold else { continue }

                guard let fileData = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                      let sessionJson = try? JSONSerialization.jsonObject(with: fileData) as? [String: Any],
                      let sessionId = sessionJson["sessionId"] as? String else { continue }

                if store.contains(sessionId) { continue }

                var state = AISessionState(sessionId: sessionId, source: .gemini)
                state.cwd = cwd
                state.lastEventTime = modDate
                sessionFiles[sessionId] = filePath
                fileMonitoredSessions.insert(sessionId)

                applyParsedContent(to: &state, filePath: filePath)
                store.upsert(state)
            }
        }

        if !fileMonitoredSessions.isEmpty {
            LogService.info("Gemini: discovered \(fileMonitoredSessions.count) existing session(s)", category: "GeminiProvider")
            startFileMonitoring()
        }
    }

    private func applyParsedContent(to session: inout AISessionState, filePath: String) {
        guard let result = GeminiConversationParser.parseDetailed(filePath: filePath) else { return }

        session.messages = result.common.messages
        session.inputTokens = result.common.inputTokens
        session.outputTokens = result.common.outputTokens
        session.cacheReadTokens = result.cachedTokens
        if let model = result.common.lastModel { session.model = model }

        let userMessages = result.common.messages.filter { $0.role == .user }
        if let first = userMessages.first, session.firstUserMessage == nil {
            session.firstUserMessage = String(first.content.prefix(80))
        }
        if let last = userMessages.last {
            session.lastUserMessage = String(last.content.prefix(80))
        }

        let meaningful = result.common.messages.filter { ![.tool, .toolResult, .system].contains($0.role) }
        if let lastMsg = meaningful.last {
            switch lastMsg.role {
            case .user: session.phase = .processing
            case .assistant: session.phase = .waitingForInput
            default: session.phase = .idle
            }
        } else {
            session.phase = .idle
        }
    }

    private func startFileMonitoring() {
        guard fileMonitorTimer == nil else { return }
        fileMonitorTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollFileChanges()
            }
        }
    }

    private func stopFileMonitoring() {
        fileMonitorTimer?.invalidate()
        fileMonitorTimer = nil
    }

    private func pollFileChanges() {
        let monitored = fileMonitoredSessions
        var staleIds: Set<String> = []
        var changedSessions: [(String, Date)] = []
        var degradedIds: Set<String> = []

        for sessionId in monitored {
            guard let filePath = sessionFiles[sessionId],
                  let session = store.get(sessionId) else { continue }

            if !FileManager.default.fileExists(atPath: filePath) {
                staleIds.insert(sessionId)
                continue
            }

            if session.phase == .processing || session.phase == .waitingForInput {
                if let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                   let modDate = attrs[.modificationDate] as? Date,
                   Date().timeIntervalSince(modDate) > 120 {
                    degradedIds.insert(sessionId)
                    continue
                }
            }

            guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                  let modDate = attrs[.modificationDate] as? Date,
                  modDate > session.lastEventTime else { continue }

            changedSessions.append((sessionId, modDate))
        }

        for id in staleIds {
            fileMonitoredSessions.remove(id)
            sessionFiles.removeValue(forKey: id)
            store.remove(id)
        }

        for id in degradedIds {
            store.mutate(id) { session in session.phase = .idle }
        }

        for (sessionId, modDate) in changedSessions {
            guard let filePath = sessionFiles[sessionId] else { continue }
            store.mutate(sessionId) { session in
                session.lastEventTime = modDate
                self.applyParsedContent(to: &session, filePath: filePath)
            }
        }

        if fileMonitoredSessions.isEmpty {
            stopFileMonitoring()
        }
    }

    // MARK: - Helpers

    private func applyContext(to session: inout AISessionState, event: HookEvent) {
        if let cwd = event.cwd { session.cwd = cwd }
        if let msg = event.message, !msg.isEmpty { session.lastMessage = msg }
        session.lastEventName = event.hookEventName
    }

    // MARK: - Conversation Parsing

    private func parseConversation(for sessionId: String) {
        if sessionFiles[sessionId] == nil {
            if let filePath = resolveFile(for: sessionId) {
                sessionFiles[sessionId] = filePath
            }
        }

        guard let filePath = sessionFiles[sessionId] else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.parseConversation(for: sessionId)
            }
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = GeminiConversationParser.parseDetailed(filePath: filePath)

            DispatchQueue.main.async {
                guard let self else { return }
                self.store.mutateOrCreate(sessionId, source: .gemini) { session in
                    if let result {
                        LogService.info("Gemini parsed \(result.common.messages.count) messages for \(sessionId.prefix(8))", category: "GeminiProvider")
                        session.messages = result.common.messages
                        session.inputTokens = result.common.inputTokens
                        session.outputTokens = result.common.outputTokens
                        session.cacheReadTokens = result.cachedTokens
                        if let model = result.common.lastModel { session.model = model }

                        let userMessages = result.common.messages.filter { $0.role == .user }
                        if let first = userMessages.first, session.firstUserMessage == nil {
                            session.firstUserMessage = String(first.content.prefix(80))
                        }
                        if let last = userMessages.last {
                            session.lastUserMessage = String(last.content.prefix(80))
                        }
                    } else {
                        LogService.error("Gemini failed to parse result for \(sessionId.prefix(8))", category: "GeminiProvider")
                    }
                }
            }
        }
    }

    private func resolveFile(for sessionId: String) -> String? {
        guard let cwd = store.get(sessionId)?.cwd else { return nil }
        return GeminiConversationParser.findSessionFile(sessionId: sessionId, cwd: cwd)
    }

    // MARK: - Timeout

    private func scheduleTimeoutCleanup() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cleanupStaleSessions()
            }
        }
    }

    private func cleanupStaleSessions() {
        let threshold = Date().addingTimeInterval(-1800)
        let stale = store.sessions(for: .gemini).filter { $0.lastEventTime < threshold }
        for session in stale {
            sessionFiles.removeValue(forKey: session.id)
            store.remove(session.id)
        }
    }
}
