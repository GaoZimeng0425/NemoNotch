import Foundation

@Observable
final class GeminiProvider: AIProvider {
    let source: AISource = .gemini
    var sessions: [String: AISessionState] = [:]
    var activeSession: AISessionState?
    var isHookInstalled = false

    private var timeoutTimer: Timer?
    private var sessionFiles: [String: String] = [:]
    private var fileMonitoredSessions: Set<String> = []
    private var fileMonitorTimer: Timer?
    private weak var hookServer: HookServer?

    init() {
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
        if var session = sessions[sessionId] {
            session.phase = session.phase.transition(to: .processing)
            sessions[sessionId] = session
            updateActiveSession()
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
            sessions[sessionId] = session
            parseConversation(for: sessionId)

        case "BeforeAgent": // Maps to UserPromptSubmit
            var session = ensureSession(sessionId)
            session.phase = .processing
            applyContext(to: &session, event: event)
            session.lastEventTime = now
            sessions[sessionId] = session
            parseConversation(for: sessionId)

        case "BeforeTool": // Maps to PreToolUse
            var session = ensureSession(sessionId)
            session.phase = .processing
            session.currentTool = event.toolName
            session.isPreToolUse = true
            applyContext(to: &session, event: event)
            session.lastEventTime = now
            if let toolName = event.toolName, toolName == "invoke_subagent" {
                session.subagentState.startTask(
                    taskToolId: event.toolUseId ?? UUID().uuidString,
                    description: "Subagent"
                )
            }
            sessions[sessionId] = session
            parseConversation(for: sessionId)

        case "AfterTool": // Maps to PostToolUse
            var session = ensureSession(sessionId)
            session.currentTool = nil
            session.isPreToolUse = false
            applyContext(to: &session, event: event)
            session.lastEventTime = now
            if let toolName = event.toolName, toolName == "invoke_subagent" {
                session.subagentState.stopTask(taskToolId: event.toolUseId ?? "")
            }
            sessions[sessionId] = session
            parseConversation(for: sessionId)

        case "Notification":
            var session = ensureSession(sessionId)
            session.phase = .waitingForInput
            applyContext(to: &session, event: event)
            session.lastEventTime = now
            sessions[sessionId] = session
            parseConversation(for: sessionId)

        case "AfterAgent": // Maps to Stop
            if var session = sessions[sessionId] {
                session.phase = .waitingForInput
                session.currentTool = nil
                session.isPreToolUse = false
                applyContext(to: &session, event: event)
                session.lastEventTime = now
                sessions[sessionId] = session
                parseConversation(for: sessionId)
            }

        case "SessionEnd":
            sessionFiles.removeValue(forKey: sessionId)
            sessions.removeValue(forKey: sessionId)

        default:
            break
        }

        updateActiveSession()
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

                if sessions[sessionId] != nil { continue }

                var state = AISessionState(sessionId: sessionId, source: .gemini)
                state.cwd = cwd
                state.lastEventTime = modDate
                sessionFiles[sessionId] = filePath
                fileMonitoredSessions.insert(sessionId)

                applyParsedContent(to: &state, filePath: filePath)

                sessions[sessionId] = state
            }
        }

        if !fileMonitoredSessions.isEmpty {
            LogService.info("Gemini: discovered \(fileMonitoredSessions.count) existing session(s)", category: "GeminiProvider")
            updateActiveSession()
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
            self?.pollFileChanges()
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
                  let session = sessions[sessionId] else { continue }

            if !FileManager.default.fileExists(atPath: filePath) {
                staleIds.insert(sessionId)
                continue
            }

            // Degrade active sessions whose file hasn't changed in 2 minutes
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
            sessions.removeValue(forKey: id)
        }

        for id in degradedIds {
            if var session = sessions[id] {
                session.phase = .idle
                sessions[id] = session
            }
        }

        for (sessionId, modDate) in changedSessions {
            guard var session = sessions[sessionId] else { continue }
            session.lastEventTime = modDate
            applyParsedContent(to: &session, filePath: sessionFiles[sessionId] ?? "")
            sessions[sessionId] = session
        }

        if !changedSessions.isEmpty || !staleIds.isEmpty || !degradedIds.isEmpty {
            updateActiveSession()
        }
        if fileMonitoredSessions.isEmpty {
            stopFileMonitoring()
        }
    }

    // MARK: - Helpers

    private func ensureSession(_ sessionId: String) -> AISessionState {
        if let existing = sessions[sessionId] { return existing }
        return AISessionState(sessionId: sessionId, source: .gemini)
    }

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
            // If file still not found, try again in a second
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.parseConversation(for: sessionId)
            }
            return 
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = GeminiConversationParser.parseDetailed(filePath: filePath)

            DispatchQueue.main.async {
                guard let self else { return }
                var session = self.sessions[sessionId] ?? AISessionState(sessionId: sessionId, source: .gemini)

                if let result = result {
                    LogService.info("Gemini parsed \(result.common.messages.count) messages for \(sessionId.prefix(8))", category: "GeminiProvider")
                    session.messages = result.common.messages
                    session.inputTokens = result.common.inputTokens
                    session.outputTokens = result.common.outputTokens
                    session.cacheReadTokens = result.cachedTokens
                    if let model = result.common.lastModel {
                        session.model = model
                    }

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

                self.sessions[sessionId] = session
                self.updateActiveSession()
            }
        }
    }

    private func resolveFile(for sessionId: String) -> String? {
        guard let cwd = sessions[sessionId]?.cwd else { return nil }
        return GeminiConversationParser.findSessionFile(sessionId: sessionId, cwd: cwd)
    }

    // MARK: - Active Session

    private func updateActiveSession() {
        let prevId = activeSession?.id
        let allSessions = Array(sessions.values)
        let sortedSessions = allSessions.sorted { s1, s2 in
            sessionPriority(s1) > sessionPriority(s2)
        }
        activeSession = sortedSessions.first

        if activeSession?.id != prevId {
            LogService.info("Gemini active session: \(prevId ?? "nil") -> \(activeSession?.id ?? "nil")", category: "GeminiProvider")
        }
    }

    private func sessionPriority(_ session: AISessionState) -> Int {
        switch session.phase {
        case .processing: return 80
        case .compacting: return 70
        case .waitingForInput: return 50
        case .idle: return 10
        case .ended: return 0
        case .waitingForApproval: return 100
        }
    }

    // MARK: - Timeout

    private func scheduleTimeoutCleanup() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            self?.cleanupStaleSessions()
        }
    }

    private func cleanupStaleSessions() {
        let threshold = Date().addingTimeInterval(-1800)
        let staleIds = sessions.filter { $0.value.lastEventTime < threshold }.map(\.key)
        for id in staleIds {
            sessionFiles.removeValue(forKey: id)
            sessions.removeValue(forKey: id)
        }
        updateActiveSession()
    }
}
