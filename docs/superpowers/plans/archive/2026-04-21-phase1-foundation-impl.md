# Phase 1: Foundation — Transport & State Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace TCP hook server with Unix domain socket, add session state machine, incremental JSONL parser, and interrupt detection.

**Architecture:** Keep NemoNotch's `@Observable` service pattern. Replace the NWListener TCP server with a GCD-based Unix socket server. Add a `SessionPhase` state machine to `ClaudeState`. Add `ConversationParser` and `InterruptWatcher` as standalone services consumed by `ClaudeCodeService`.

**Tech Stack:** Swift 5, SwiftUI, Foundation (GCD, FileManager), Network (removed)

**Reference:** vibe-notch at `/Users/gaozimeng/Learn/macOS/vibe-notch/`

---

### Task 1: Create SessionPhase State Machine

**Files:**
- Create: `NemoNotch/Models/SessionPhase.swift`

**Step 1: Create the SessionPhase model**

```swift
// NemoNotch/Models/SessionPhase.swift
import Foundation

enum SessionPhase: Equatable {
    case idle
    case processing
    case waitingForInput
    case waitingForApproval(PermissionContext)
    case compacting
    case ended

    var needsAttention: Bool {
        switch self {
        case .waitingForInput, .waitingForApproval: true
        default: false
        }
    }

    var isActive: Bool {
        switch self {
        case .processing, .compacting, .waitingForApproval: true
        default: false
        }
    }

    var isWaitingForApproval: Bool {
        if case .waitingForApproval = self { return true }
        return false
    }

    var approvalToolName: String? {
        if case .waitingForApproval(let ctx) = self { return ctx.toolName }
        return nil
    }

    func canTransition(to next: SessionPhase) -> Bool {
        switch (self, next) {
        case (.idle, .processing), (.idle, .ended):
            return true
        case (.processing, .waitingForInput),
             (.processing, .waitingForApproval),
             (.processing, .compacting),
             (.processing, .idle),
             (.processing, .ended):
            return true
        case (.waitingForInput, .processing),
             (.waitingForInput, .ended):
            return true
        case (.waitingForApproval, .processing),
             (.waitingForApproval, .ended):
            return true
        case (.compacting, .processing),
             (.compacting, .ended):
            return true
        case (.ended, _):
            return false
        default:
            return false
        }
    }

    func transition(to next: SessionPhase) -> SessionPhase {
        guard canTransition(to: next) else {
            LogService.warn("Invalid phase transition: \(self) → \(next)", category: "SessionPhase")
            return self
        }
        return next
    }
}

struct PermissionContext: Equatable {
    let toolUseId: String
    let toolName: String
    let toolInput: String?
    let receivedAt: Date

    var displayInput: String {
        guard let input = toolInput, !input.isEmpty else { return "" }
        if input.count > 120 {
            return String(input.prefix(120)) + "..."
        }
        return input
    }

    static func == (lhs: PermissionContext, rhs: PermissionContext) -> Bool {
        lhs.toolUseId == rhs.toolUseId
    }
}
```

**Step 2: Add file to Xcode project**

In Xcode: File → Add Files to "NemoNotch" → select `Models/SessionPhase.swift`

**Step 3: Build to verify**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (no errors, possibly unused variable warnings)

**Step 4: Commit**

```bash
git add NemoNotch/Models/SessionPhase.swift
git commit -m "feat: add SessionPhase state machine for Claude sessions"
```

---

### Task 2: Create ChatMessage Model

**Files:**
- Create: `NemoNotch/Models/ChatMessage.swift`

**Step 1: Create the ChatMessage model**

```swift
// NemoNotch/Models/ChatMessage.swift
import Foundation

enum ChatMessageRole: String, Codable {
    case user
    case assistant
    case tool
    case toolResult
    case system
}

struct ChatMessage: Identifiable {
    let id: String
    let role: ChatMessageRole
    let content: String
    let toolName: String?
    let toolInput: String?
    let timestamp: Date

    init(id: String, role: ChatMessageRole, content: String, toolName: String? = nil, toolInput: String? = nil, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.content = content
        self.toolName = toolName
        self.toolInput = toolInput
        self.timestamp = timestamp
    }
}
```

**Step 2: Add file to Xcode project**

**Step 3: Build to verify**

**Step 4: Commit**

```bash
git add NemoNotch/Models/ChatMessage.swift
git commit -m "feat: add ChatMessage model for conversation history"
```

---

### Task 3: Update ClaudeState to Use SessionPhase

**Files:**
- Modify: `NemoNotch/Models/ClaudeState.swift`

**Step 1: Rewrite ClaudeState**

Replace the entire file. The old `ClaudeStatus` enum is kept for backward compatibility with `CompactBadge` — it's now derived from `SessionPhase`.

```swift
// NemoNotch/Models/ClaudeState.swift
import Foundation

struct ClaudeState: Identifiable {
    let id: String
    var phase: SessionPhase = .idle
    var currentTool: String?
    var cwd: String?
    var lastMessage: String?
    var lastEventName: String?
    var isPreToolUse = false
    var sessionStart: Date
    var lastEventTime: Date
    var firstUserMessage: String?
    var lastUserMessage: String?
    var messages: [ChatMessage] = []
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var lastParsedOffset: UInt64 = 0

    init(sessionId: String) {
        self.id = sessionId
        self.sessionStart = Date()
        self.lastEventTime = Date()
    }

    var projectFolder: String? {
        guard let cwd else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    var displayTitle: String {
        if let msg = firstUserMessage, !msg.isEmpty { return msg }
        if let folder = projectFolder { return folder }
        return "Session \(id.prefix(8))"
    }

    /// Derived status for backward compatibility with CompactBadge and ClaudeTab
    var status: ClaudeStatus {
        switch phase {
        case .idle, .ended: return .idle
        case .processing, .compacting: return .working
        case .waitingForInput: return .waiting
        case .waitingForApproval: return .waiting
        }
    }

    var totalTokens: Int { inputTokens + outputTokens }

    var tokenDisplay: String {
        let total = totalTokens
        if total >= 1000 {
            return String(format: "%.1fk", Double(total) / 1000.0)
        }
        return "\(total)"
    }
}

/// Legacy status enum kept for UI compatibility
enum ClaudeStatus: Equatable {
    case idle
    case working
    case waiting
}
```

**Step 2: Build to verify**

The build should succeed because `ClaudeStatus` is still available and `ClaudeState.status` is a computed property that returns the same type.

**Step 3: Commit**

```bash
git add NemoNotch/Models/ClaudeState.swift
git commit -m "refactor: upgrade ClaudeState with SessionPhase and token tracking"
```

---

### Task 4: Rewrite HookServer for Unix Domain Socket

**Files:**
- Modify: `NemoNotch/Services/HookServer.swift`
- Modify: `NemoNotch/Helpers/Constants.swift` (remove TCP port constants, add socket path)

**Step 1: Update Constants**

In `NemoNotch/Helpers/Constants.swift`, remove lines 42-43 (hookBasePort, hookMaxPortAttempts) and add:

```swift
// Hook server
static let hookSocketPath = "/tmp/nemonotch.sock"
```

**Step 2: Rewrite HookServer**

Replace the entire `HookServer.swift` with a GCD-based Unix socket server. Key differences from the old TCP version:

- Uses `DispatchSourceRead` instead of `NWListener`
- Listens on `/tmp/nemonotch.sock`
- Supports request-response protocol (needed for Phase 3 permissions)
- Sends JSON responses that the hook script can read

```swift
// NemoNotch/Services/HookServer.swift
import Foundation

@Observable
final class HookServer {
    private(set) var isRunning = false
    private var socketFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let socketQueue = DispatchQueue(label: "com.nemonotch.hookserver", qos: .userInitiated)

    // Pending permission responses keyed by toolUseId
    private var pendingResponses: [String: String] = [:]
    private var responseWaiters: [String: (String) -> Void] = [:]

    var onEventReceived: ((HookEvent) -> Void)?
    var onReady: (() -> Void)?

    func start() {
        socketQueue.async { [weak self] in
            self?.doStart()
        }
    }

    private func doStart() {
        // Remove stale socket
        unlink(NotchConstants.hookSocketPath)

        socketFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFd >= 0 else {
            LogService.error("Failed to create socket: \(String(cString: strerror(errno)))", category: "HookServer")
            return
        }

        // Allow address reuse
        var optval: Int32 = 1
        setsockopt(socketFd, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout.size(ofValue: optval)))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathData = NotchConstants.hookSocketPath.withCString { ptr in
            return ptr.withMemoryRebound(to: CChar.self, capacity: 104) { rebased in
                strncpy(&addr.sun_path.0, rebased, 103)
                return strlen(&addr.sun_path.0)
            }
        }

        let bindResult = bind(socketFd, withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
        }, socklen_t(MemoryLayout<sockaddr_un>.size))

        guard bindResult == 0 else {
            LogService.error("Failed to bind socket: \(String(cString: strerror(errno)))", category: "HookServer")
            close(socketFd)
            socketFd = -1
            return
        }

        guard listen(socketFd, 10) == 0 else {
            LogService.error("Failed to listen on socket: \(String(cString: strerror(errno)))", category: "HookServer")
            close(socketFd)
            socketFd = -1
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.isRunning = true
            self?.onReady?()
        }

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: socketFd, queue: socketQueue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.resume()

        LogService.info("Hook server listening on \(NotchConstants.hookSocketPath)", category: "HookServer")
    }

    private func acceptConnection() {
        var addr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFd = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebased in
                accept(socketFd, rebased, &addrLen)
            }
        }

        guard clientFd >= 0 else { return }

        readRequest(fd: clientFd)
    }

    private func readRequest(fd: Int32) {
        // Read data from socket with timeout
        var buffer = Data()
        var tempBuf = [UInt8](repeating: 0, count: 4096)

        while true {
            let bytesRead = read(fd, &tempBuf, tempBuf.count)
            if bytesRead > 0 {
                buffer.append(tempBuf, count: bytesRead)
                // Check if we have a complete message (newline-delimited JSON)
                if let str = String(data: buffer, encoding: .utf8), str.hasSuffix("\n") {
                    break
                }
            } else {
                break
            }
        }

        guard let message = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            close(fd)
            return
        }

        // Try to parse as JSON
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Send error response
            sendResponse(fd: fd, response: #"{"error":"invalid json"}"#)
            return
        }

        // Handle health check
        if json["type"] as? String == "health" {
            sendResponse(fd: fd, response: #"{"status":"ok"}"#)
            return
        }

        // Parse as HookEvent
        let decoder = JSONDecoder()
        if let event = try? decoder.decode(HookEvent.self, from: data) {
            DispatchQueue.main.async { [weak self] in
                self?.onEventReceived?(event)
            }

            // For permission requests, wait for user response
            if event.hookEventName == "PermissionRequest" {
                handlePermissionRequest(event, fd: fd)
                return // Don't close fd yet — we'll respond after user action
            }

            sendResponse(fd: fd, response: #"{"status":"ok"}"#)
        } else {
            sendResponse(fd: fd, response: #"{"status":"ok"}"#)
        }
    }

    private func handlePermissionRequest(_ event: HookEvent, fd: Int32) {
        guard let sessionId = event.sessionId else {
            sendResponse(fd: fd, response: #"{"decision":"deny","reason":"no session id"}"#)
            return
        }

        // Store waiter — ClaudeCodeService will call respondToPermission when user acts
        responseWaiters[sessionId] = { [weak self] response in
            self?.sendResponse(fd: fd, response: response)
        }

        // Timeout after 120 seconds
        socketQueue.asyncAfter(deadline: .now() + 120) { [weak self] in
            if let waiter = self?.responseWaiters.removeValue(forKey: sessionId) {
                waiter(#"{"decision":"deny","reason":"timeout"}"#)
            }
        }
    }

    func respondToPermission(sessionId: String, approved: Bool) {
        let response = #"{"decision":"\#(approved ? "allow" : "deny")"}"#
        socketQueue.async { [weak self] in
            if let waiter = self?.responseWaiters.removeValue(forKey: sessionId) {
                waiter(response)
            }
        }
    }

    private func sendResponse(fd: Int32, response: String) {
        let data = (response + "\n").data(using: .utf8) ?? Data()
        _ = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, data.count)
        }
        close(fd)
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        if socketFd >= 0 {
            close(socketFd)
            socketFd = -1
        }
        unlink(NotchConstants.hookSocketPath)
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
        }
    }

    deinit {
        stop()
    }
}
```

**Step 3: Build to verify**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED. There will be compile errors in `ClaudeCodeService` referencing `serverPort` — we'll fix those in Task 8.

If build fails due to missing `serverPort`: temporarily add `var serverPort: UInt16 = 0` to HookServer. We'll clean this up in Task 8.

**Step 4: Commit**

```bash
git add NemoNotch/Services/HookServer.swift NemoNotch/Helpers/Constants.swift
git commit -m "refactor: replace TCP hook server with Unix domain socket"
```

---

### Task 5: Update HookInstaller for Unix Socket

**Files:**
- Modify: `NemoNotch/Services/HookInstaller.swift`

**Step 1: Rewrite hook script and installer**

The shell script changes from `curl` to `nc -U`. The installer no longer needs port management.

Replace `NemoNotch/Services/HookInstaller.swift`:

```swift
// NemoNotch/Services/HookInstaller.swift
import Foundation

enum HookInstaller {
    private static let claudeSettingsPath = NSHomeDirectory() + "/.claude/settings.json"
    private static let hookScriptDir = NSHomeDirectory() + "/.nemonotch/hooks"
    private static let hookScriptPath = hookScriptDir + "/hook-sender.sh"
    private static var hookCommand: String { "~/.nemonotch/hooks/hook-sender.sh" }
    private static let socketPath = NotchConstants.hookSocketPath

    private static let hookEvents = [
        "PreToolUse",
        "PostToolUse",
        "Stop",
        "SessionStart",
        "SessionEnd",
        "Notification",
        "UserPromptSubmit",
        "PermissionRequest",
    ]

    private static let scriptVersion = "# version: 3"

    static func isInstalled() -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: claudeSettingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        for event in hookEvents {
            if let entries = hooks[event] as? [[String: Any]],
               entries.contains(where: { entry in
                   guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                   return innerHooks.contains { ($0["command"] as? String) == hookCommand }
               }) {
                return true
            }
        }
        return false
    }

    static func install() throws {
        try ensureScriptExists()

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: claudeSettingsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let hookEntry: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": hookCommand]],
        ]

        for event in hookEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let alreadyRegistered = entries.contains { entry in
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return innerHooks.contains { ($0["command"] as? String) == hookCommand }
            }
            if !alreadyRegistered {
                entries.append(hookEntry)
            }
            hooks[event] = entries
        }

        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    static func uninstall() throws {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: claudeSettingsPath)),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else {
            return
        }

        for event in hookEvents {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return innerHooks.contains { ($0["command"] as? String) == hookCommand }
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        try writeSettings(settings)
    }

    static func ensureScriptExists() throws {
        let scriptURL = URL(fileURLWithPath: hookScriptPath)

        if FileManager.default.fileExists(atPath: hookScriptPath),
           let contents = try? String(contentsOf: scriptURL, encoding: .utf8),
           contents.contains(scriptVersion) {
            return
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: hookScriptDir),
            withIntermediateDirectories: true
        )

        // Uses nc (netcat) with Unix socket for fast, reliable communication.
        // For PermissionRequest: reads response from socket (needed for approve/deny flow).
        // For all other events: fire-and-forget.
        let script = """
        #!/bin/bash
        \(scriptVersion)
        SOCKET="\(socketPath)"
        [ -S "$SOCKET" ] || exit 0
        INPUT=$(cat 2>/dev/null || echo '{}')
        echo "$INPUT" | nc -U -q 0 "$SOCKET" 2>/dev/null || true
        exit 0
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hookScriptPath
        )
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let claudeDir = (claudeSettingsPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: claudeDir,
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: claudeSettingsPath))
    }
}
```

Key changes from old version:
- Removed `port` parameter from `install()` — socket path is fixed
- Removed `currentPort` property — no port management
- Added `PermissionRequest` to `hookEvents` list
- Script uses `nc -U` instead of `curl`
- Script version bumped to 3

**Step 2: Build to verify**

**Step 3: Commit**

```bash
git add NemoNotch/Services/HookInstaller.swift
git commit -m "refactor: update HookInstaller for Unix socket, add PermissionRequest hook"
```

---

### Task 6: Create ConversationParser

**Files:**
- Create: `NemoNotch/Services/ConversationParser.swift`

**Step 1: Create the parser**

This is an incremental JSONL parser adapted from vibe-notch's `ConversationParser`. It parses Claude Code's conversation JSONL files and extracts messages, tool calls, and token usage.

```swift
// NemoNotch/Services/ConversationParser.swift
import Foundation

enum ConversationParser {

    struct ParseResult {
        var messages: [ChatMessage]
        var inputTokens: Int
        var outputTokens: Int
        var newOffset: UInt64
        var interrupted: Bool
        var cleared: Bool
    }

    // MARK: - File Discovery

    /// Find the JSONL file path for a session
    static func conversationPath(sessionId: String, cwd: String) -> String? {
        let dir = claudeProjectsDir(for: cwd)
        let path = "\(dir)/\(sessionId).jsonl"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Get all conversation files in a project directory
    static func conversationFiles(for cwd: String) -> [String] {
        let dir = claudeProjectsDir(for: cwd)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.filter { $0.hasSuffix(".jsonl") }.map { "\(dir)/\($0)" }
    }

    // MARK: - Incremental Parsing

    static func parseIncremental(filePath: String, fromOffset: UInt64) -> ParseResult {
        var result = ParseResult(messages: [], inputTokens: 0, outputTokens: 0, newOffset: fromOffset, interrupted: false, cleared: false)

        guard let fileHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else {
            return result
        }
        defer { try? fileHandle.close() }

        // Seek to last known offset
        if fromOffset > 0 {
            try? fileHandle.seek(toOffset: fromOffset)
        }

        guard let data = try? fileHandle.readToEnd() else { return result }
        guard let text = String(data: data, encoding: .utf8) else { return result }

        result.newOffset = fromOffset + UInt64(data.count)

        var messageIndex = 0
        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            // Check for interrupt
            if isInterruptLine(json) {
                result.interrupted = true
                continue
            }

            // Check for clear
            if isClearLine(json) {
                result.cleared = true
                result.messages = [] // Reset messages on clear
                continue
            }

            // Parse usage info
            if let usage = json["usage"] as? [String: Any] {
                result.inputTokens += usage["input_tokens"] as? Int ?? 0
                result.outputTokens += usage["output_tokens"] as? Int ?? 0
            }

            // Parse message
            if let message = parseMessage(json, index: messageIndex) {
                result.messages.append(message)
                messageIndex += 1
            }
        }

        return result
    }

    // MARK: - Full File Parsing (for initial load)

    static func parseFull(filePath: String) -> ParseResult {
        parseIncremental(filePath: filePath, fromOffset: 0)
    }

    // MARK: - Private Helpers

    private static func claudeProjectsDir(for cwd: String) -> String {
        let encoded = "-" + cwd.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "-")
        return NSString(string: "~/.claude/projects/\(encoded)").expandingTildeInPath
    }

    private static func parseMessage(_ json: [String: Any], index: Int) -> ChatMessage? {
        guard let type = json["type"] as? String else { return nil }

        switch type {
        case "user":
            return parseUserMessage(json, index: index)
        case "assistant":
            return parseAssistantMessage(json, index: index)
        case "tool_result":
            return parseToolResult(json, index: index)
        default:
            return nil
        }
    }

    private static func parseUserMessage(_ json: [String: Any], index: Int) -> ChatMessage? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        let text = extractText(from: message)
        guard !text.isEmpty else { return nil }
        return ChatMessage(
            id: "user-\(index)",
            role: .user,
            content: text,
            timestamp: parseTimestamp(json) ?? Date()
        )
    }

    private static func parseAssistantMessage(_ json: [String: Any], index: Int) -> ChatMessage? {
        guard let message = json["message"] as? [String: Any] else { return nil }

        // Extract text content
        let text = extractText(from: message)

        // Check for tool_use in content blocks
        if let content = message["content"] as? [[String: Any]] {
            for block in content {
                if block["type"] as? String == "tool_use",
                   let toolName = block["name"] as? String {
                    let input = block["input"]
                    let inputStr = input.flatMap { try? String(data: JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), encoding: .utf8) }
                    return ChatMessage(
                        id: "tool-\(index)",
                        role: .tool,
                        content: text.isEmpty ? "Using \(toolName)" : text,
                        toolName: toolName,
                        toolInput: inputStr,
                        timestamp: parseTimestamp(json) ?? Date()
                    )
                }
            }
        }

        guard !text.isEmpty else { return nil }
        return ChatMessage(
            id: "assistant-\(index)",
            role: .assistant,
            content: text,
            timestamp: parseTimestamp(json) ?? Date()
        )
    }

    private static func parseToolResult(_ json: [String: Any], index: Int) -> ChatMessage? {
        guard let message = json["message"] as? [String: Any] else { return nil }
        let content = message["content"]
        var text = ""
        if let str = content as? String {
            text = str
        } else if let arr = content as? [[String: Any]] {
            for item in arr {
                if item["type"] as? String == "text", let t = item["text"] as? String {
                    text = t
                    break
                }
            }
        }
        guard !text.isEmpty else { return nil }

        let toolUseId = message["tool_use_id"] as? String
        return ChatMessage(
            id: "result-\(index)",
            role: .toolResult,
            content: String(text.prefix(500)),
            toolName: toolUseId,
            timestamp: parseTimestamp(json) ?? Date()
        )
    }

    private static func extractText(from message: [String: Any]) -> String {
        guard let content = message["content"] else { return "" }
        if let str = content as? String { return str }
        if let array = content as? [[String: Any]] {
            var texts: [String] = []
            for item in array {
                if item["type"] as? String == "text", let text = item["text"] as? String {
                    texts.append(text)
                }
            }
            return texts.joined(separator: "\n")
        }
        return ""
    }

    private static func parseTimestamp(_ json: [String: Any]) -> Date? {
        guard let ts = json["timestamp"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: ts)
    }

    // MARK: - Interrupt & Clear Detection

    private static let interruptPatterns = [
        "Interrupted by user",
        "interrupted by user",
        "user doesn't want to proceed",
        "[Request interrupted by user",
    ]

    private static func isInterruptLine(_ json: [String: Any]) -> Bool {
        guard let message = json["message"] as? [String: Any] else { return false }
        let text = extractText(from: message).lowercased()
        return interruptPatterns.contains { text.contains($0.lowercased()) }
    }

    private static func isClearLine(_ json: [String: Any]) -> Bool {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { block in
            guard block["type"] as? String == "text", let text = block["text"] as? String else { return false }
            return text.contains("/clear") || text.contains("/compact")
        }
    }
}
```

**Step 2: Add file to Xcode project**

**Step 3: Build to verify**

**Step 4: Commit**

```bash
git add NemoNotch/Services/ConversationParser.swift
git commit -m "feat: add ConversationParser for incremental JSONL parsing"
```

---

### Task 7: Create InterruptWatcher

**Files:**
- Create: `NemoNotch/Services/InterruptWatcher.swift`

**Step 1: Create the watcher**

Uses `DispatchSourceFileSystemObject` to monitor JSONL file changes in real-time. When an interrupt or clear is detected, calls back to `ClaudeCodeService`.

```swift
// NemoNotch/Services/InterruptWatcher.swift
import Foundation

final class InterruptWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private let filePath: String
    private let sessionId: String
    private var lastOffset: UInt64 = 0
    private let queue = DispatchQueue(label: "com.nemonotch.interruptwatcher", qos: .utility)

    var onInterrupt: ((String) -> Void)?  // sessionId
    var onClear: ((String) -> Void)?

    init(sessionId: String, filePath: String) {
        self.sessionId = sessionId
        self.filePath = filePath
    }

    func start() {
        guard FileManager.default.fileExists(atPath: filePath) else { return }

        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) else { return }
        self.fileHandle = handle

        // Start watching from end of file
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? UInt64) ?? 0
        lastOffset = fileSize

        let fd = handle.fileDescriptor
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: queue
        )

        source?.setEventHandler { [weak self] in
            self?.checkForChanges()
        }

        source?.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func checkForChanges() {
        guard let handle = fileHandle else { return }

        let currentSize = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size] as? UInt64) ?? 0
        guard currentSize > lastOffset else { return }

        try? handle.seek(toOffset: lastOffset)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else {
            lastOffset = currentSize
            return
        }

        lastOffset = currentSize

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty, let lineData = line.data(using: .utf8) else { continue }
            guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            if isInterruptLine(json) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onInterrupt?(self.sessionId)
                }
            }

            if isClearLine(json) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.onClear?(self.sessionId)
                }
            }
        }
    }

    // MARK: - Detection Patterns

    private static let interruptPatterns = [
        "interrupted by user",
        "user doesn't want to proceed",
        "[request interrupted by user",
    ]

    private func isInterruptLine(_ json: [String: Any]) -> Bool {
        guard let message = json["message"] as? [String: Any] else { return false }
        let content = message["content"]
        var text = ""
        if let str = content as? String { text = str }
        else if let arr = content as? [[String: Any]] {
            for item in arr {
                if item["type"] as? String == "text", let t = item["text"] as? String {
                    text += t
                }
            }
        }
        let lower = text.lowercased()
        return Self.interruptPatterns.contains { lower.contains($0) }
    }

    private func isClearLine(_ json: [String: Any]) -> Bool {
        guard let message = json["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return false }
        return content.contains { block in
            guard block["type"] as? String == "text", let text = block["text"] as? String else { return false }
            return text.contains("/clear") || text.contains("/compact")
        }
    }
}

/// Manages InterruptWatchers for all active sessions
final class InterruptWatcherManager {
    private var watchers: [String: InterruptWatcher] = [:]

    func startWatching(sessionId: String, cwd: String) {
        guard let filePath = ConversationParser.conversationPath(sessionId: sessionId, cwd: cwd) else { return }
        guard watchers[sessionId] == nil else { return }

        let watcher = InterruptWatcher(sessionId: sessionId, filePath: filePath)
        watcher.onInterrupt = { [weak self] sessionId in
            self?.handleInterrupt(sessionId: sessionId)
        }
        watcher.onClear = { [weak self] sessionId in
            self?.handleClear(sessionId: sessionId)
        }
        watchers[sessionId] = watcher
        watcher.start()
    }

    func stopWatching(sessionId: String) {
        watchers[sessionId]?.stop()
        watchers.removeValue(forKey: sessionId)
    }

    func stopAll() {
        for (_, watcher) in watchers { watcher.stop() }
        watchers.removeAll()
    }

    var onInterrupt: ((String) -> Void)?
    var onClear: ((String) -> Void)?

    private func handleInterrupt(sessionId: String) {
        onInterrupt?(sessionId)
    }

    private func handleClear(sessionId: String) {
        onClear?(sessionId)
    }
}
```

**Step 2: Add file to Xcode project**

**Step 3: Build to verify**

**Step 4: Commit**

```bash
git add NemoNotch/Services/InterruptWatcher.swift
git commit -m "feat: add InterruptWatcher for real-time interrupt/clear detection"
```

---

### Task 8: Update ClaudeCodeService to Wire Everything Together

**Files:**
- Modify: `NemoNotch/Services/ClaudeCodeService.swift`

**Step 1: Rewrite ClaudeCodeService**

This is the big integration task. The service now uses:
- `HookServer` with Unix socket (no more port management)
- `SessionPhase` state machine instead of flat `ClaudeStatus`
- `ConversationParser` for message and token tracking
- `InterruptWatcherManager` for real-time interrupt detection

```swift
// NemoNotch/Services/ClaudeCodeService.swift
import Foundation

@Observable
final class ClaudeCodeService {
    var sessions: [String: ClaudeState] = [:]
    var activeSession: ClaudeState?
    var isHookInstalled = false
    var serverRunning = false

    let hookServer = HookServer()
    private let watcherManager = InterruptWatcherManager()

    private var timeoutTimer: Timer?
    private var parseTimers: [String: Timer] = [:]

    init() {
        hookServer.onEventReceived = { [weak self] event in
            self?.handleEvent(event)
        }
        hookServer.onReady = { [weak self] in
            guard let self else { return }
            self.serverRunning = true
            try? HookInstaller.install()
            self.isHookInstalled = HookInstaller.isInstalled()
        }
        isHookInstalled = HookInstaller.isInstalled()

        watcherManager.onInterrupt = { [weak self] sessionId in
            self?.handleInterrupt(sessionId: sessionId)
        }
        watcherManager.onClear = { [weak self] sessionId in
            self?.handleClear(sessionId: sessionId)
        }
    }

    func startServer() {
        hookServer.start()
    }

    func installHooks() {
        do {
            try HookInstaller.install()
            isHookInstalled = true
        } catch {
            LogService.error("Failed to install hooks: \(error)", category: "ClaudeCode")
        }
    }

    func uninstallHooks() {
        do {
            try HookInstaller.uninstall()
            isHookInstalled = false
        } catch {
            LogService.error("Failed to uninstall hooks: \(error)", category: "ClaudeCode")
        }
    }

    // MARK: - Permission Response (Phase 3 entry point)

    func respondToPermission(sessionId: String, approved: Bool) {
        hookServer.respondToPermission(sessionId: sessionId, approved: approved)
        if var session = sessions[sessionId] {
            session.phase = session.phase.transition(to: .processing)
            sessions[sessionId] = session
            updateActiveSession()
        }
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: HookEvent) {
        guard let sessionId = event.sessionId else { return }
        let now = Date()

        func ensureSession() {
            if sessions[sessionId] == nil {
                sessions[sessionId] = ClaudeState(sessionId: sessionId)
            }
        }

        func updateContext() {
            if let cwd = event.cwd { sessions[sessionId]?.cwd = cwd }
            if let msg = event.message, !msg.isEmpty { sessions[sessionId]?.lastMessage = msg }
            sessions[sessionId]?.lastEventName = event.hookEventName
        }

        switch event.hookEventName {
        case "SessionStart":
            sessions[sessionId] = ClaudeState(sessionId: sessionId)
            sessions[sessionId]?.phase = .idle
            updateContext()
            if let cwd = event.cwd {
                watcherManager.startWatching(sessionId: sessionId, cwd: cwd)
            }
            parseConversation(for: sessionId)

        case "UserPromptSubmit":
            ensureSession()
            sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .processing) ?? .processing
            updateContext()
            sessions[sessionId]?.lastEventTime = now
            parseConversation(for: sessionId)

        case "PreToolUse":
            ensureSession()
            sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .processing) ?? .processing
            sessions[sessionId]?.currentTool = event.toolName
            sessions[sessionId]?.isPreToolUse = true
            updateContext()
            sessions[sessionId]?.lastEventTime = now

        case "PostToolUse":
            ensureSession()
            sessions[sessionId]?.currentTool = nil
            sessions[sessionId]?.isPreToolUse = false
            updateContext()
            sessions[sessionId]?.lastEventTime = now

        case "Notification":
            ensureSession()
            sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .waitingForInput) ?? .waitingForInput
            updateContext()
            sessions[sessionId]?.lastEventTime = now

        case "PermissionRequest":
            ensureSession()
            let ctx = PermissionContext(
                toolUseId: event.toolName ?? "unknown",
                toolName: event.toolName ?? "unknown",
                toolInput: event.message,
                receivedAt: now
            )
            sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .waitingForApproval(ctx)) ?? .waitingForApproval(ctx)
            updateContext()
            sessions[sessionId]?.lastEventTime = now
            LogService.info("Permission request: \(ctx.toolName) for session \(sessionId.prefix(8))", category: "ClaudeCode")

        case "Stop":
            if sessions[sessionId] != nil {
                sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .idle) ?? .idle
                sessions[sessionId]?.currentTool = nil
                sessions[sessionId]?.isPreToolUse = false
                updateContext()
                sessions[sessionId]?.lastEventTime = now
                parseConversation(for: sessionId)
            }

        case "SessionEnd":
            watcherManager.stopWatching(sessionId: sessionId)
            parseTimers[sessionId]?.invalidate()
            parseTimers.removeValue(forKey: sessionId)
            sessions.removeValue(forKey: sessionId)

        default:
            break
        }

        updateActiveSession()
        scheduleTimeoutCleanup()
    }

    // MARK: - Interrupt & Clear Handling

    private func handleInterrupt(sessionId: String) {
        guard sessions[sessionId] != nil else { return }
        sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .idle) ?? .idle
        sessions[sessionId]?.currentTool = nil
        sessions[sessionId]?.lastEventTime = Date()
        updateActiveSession()
        LogService.info("Interrupt detected for session \(sessionId.prefix(8))", category: "ClaudeCode")
    }

    private func handleClear(sessionId: String) {
        guard sessions[sessionId] != nil else { return }
        sessions[sessionId]?.messages = []
        sessions[sessionId]?.lastParsedOffset = 0
        sessions[sessionId]?.phase = sessions[sessionId]?.phase.transition(to: .idle) ?? .idle
        LogService.info("Clear detected for session \(sessionId.prefix(8))", category: "ClaudeCode")
    }

    // MARK: - Conversation Parsing

    private func parseConversation(for sessionId: String) {
        guard let cwd = sessions[sessionId]?.cwd else { return }
        guard let filePath = ConversationParser.conversationPath(sessionId: sessionId, cwd: cwd) else { return }

        let offset = sessions[sessionId]?.lastParsedOffset ?? 0
        let result = ConversationParser.parseIncremental(filePath: filePath, fromOffset: offset)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessions[sessionId] != nil else { return }

            if result.cleared {
                self.sessions[sessionId]?.messages = []
            }
            self.sessions[sessionId]?.messages.append(contentsOf: result.messages)
            self.sessions[sessionId]?.lastParsedOffset = result.newOffset
            self.sessions[sessionId]?.inputTokens += result.inputTokens
            self.sessions[sessionId]?.outputTokens += result.outputTokens

            // Update display titles from messages
            let userMessages = result.messages.filter { $0.role == .user }
            if let first = userMessages.first, self.sessions[sessionId]?.firstUserMessage == nil {
                self.sessions[sessionId]?.firstUserMessage = String(first.content.prefix(80))
            }
            if let last = userMessages.last {
                self.sessions[sessionId]?.lastUserMessage = String(last.content.prefix(80))
            }

            if result.interrupted {
                self.handleInterrupt(sessionId: sessionId)
            }
        }
    }

    // MARK: - Active Session Management

    private func updateActiveSession() {
        let prev = activeSession?.id

        let sortedSessions = sessions.values.sorted { sessionPriority($0) > sessionPriority($1) }
        activeSession = sortedSessions.first

        if activeSession?.id != prev {
            let phaseStr: String
            if let phase = activeSession?.phase {
                phaseStr = String(describing: phase)
            } else {
                phaseStr = "nil"
            }
            LogService.info("Active session: \(prev?.prefix(8) ?? "nil") -> \(activeSession?.id.prefix(8) ?? "nil"), phase=\(phaseStr)", category: "ClaudeCode")
        }
    }

    private func sessionPriority(_ session: ClaudeState) -> Int {
        switch session.phase {
        case .waitingForApproval: return 100
        case .processing: return 80
        case .compacting: return 70
        case .waitingForInput: return 50
        case .idle: return 10
        case .ended: return 0
        }
    }

    // MARK: - Timeout Cleanup

    private func scheduleTimeoutCleanup() {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            self?.cleanupStaleSessions()
        }
    }

    private func cleanupStaleSessions() {
        let threshold = Date().addingTimeInterval(-1800)
        for (id, state) in sessions {
            if state.lastEventTime < threshold {
                watcherManager.stopWatching(sessionId: id)
                parseTimers[id]?.invalidate()
                parseTimers.removeValue(forKey: id)
                sessions.removeValue(forKey: id)
            }
        }
        updateActiveSession()
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

Watch for:
- References to old `serverPort` — should be removed now
- References to old `HookInstaller.install(port:)` — now takes no args
- References to old `ClaudeStatus` — still available as computed property

**Step 3: Fix any compile errors in ClaudeTab and CompactBadge**

These files reference `ClaudeStatus` and `ClaudeState.status` — both still exist as computed properties, so no changes should be needed. But check for:
- `claudeService.serverPort` → remove or replace
- Any direct access to removed properties

**Step 4: Commit**

```bash
git add NemoNotch/Services/ClaudeCodeService.swift
git commit -m "refactor: wire Unix socket, state machine, parser, interrupt watcher into ClaudeCodeService"
```

---

### Task 9: Update ClaudeTab UI for New States

**Files:**
- Modify: `NemoNotch/Tabs/ClaudeTab.swift`

**Step 1: Update server status display**

Replace `serverStatus` section. The server now shows socket path instead of port:

```swift
private var serverStatus: some View {
    HStack(spacing: 6) {
        Circle()
            .fill(claudeService.serverRunning ? Color.green : Color.orange)
            .frame(width: 6, height: 6)
        Text(claudeService.serverRunning ? "Unix Socket 已就绪" : "Hook 服务未启动")
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.35))
    }
    .padding(.top, 4)
}
```

**Step 2: Update session row to show token count**

Add token display to the bottom metadata row in `sessionRow`:

After the timeAgo text, add:
```swift
if session.totalTokens > 0 {
    Text("· \(session.tokenDisplay)")
        .foregroundStyle(.white.opacity(0.3))
}
```

**Step 3: Update dotColor to handle new phases**

Replace `dotColor`:
```swift
private func dotColor(_ status: ClaudeStatus) -> Color {
    switch status {
    case .idle: .gray
    case .working: .green
    case .waiting: .yellow
    }
}
```
This doesn't need changes since `ClaudeState.status` still returns `ClaudeStatus`.

**Step 4: Update eventTagStyle to include PermissionRequest**

Add to the switch in `eventTagStyle`:
```swift
case "PermissionRequest": return ("Permission", .red)
```

**Step 5: Build and verify**

**Step 6: Commit**

```bash
git add NemoNotch/Tabs/ClaudeTab.swift
git commit -m "feat: update ClaudeTab for socket status, token display, permission events"
```

---

### Task 10: Update CompactBadge for Phase-Aware States

**Files:**
- Modify: `NemoNotch/Notch/CompactBadge.swift`

**Step 1: Add permission badge state**

The `BadgeInfo` enum already handles `.claude(ClaudeStatus, String?, Bool)`. We need to add approval awareness. Since `ClaudeState.status` still returns `ClaudeStatus`, the badge will continue working, but we can enhance it.

In the `activeBadge` computed property, after the existing claude check, add priority for approval:

```swift
// 2.5. Claude waiting for approval (highest priority claude state)
if let session = claudeService.activeSession, session.phase.isWaitingForApproval {
    return .claude(.waiting, session.phase.approvalToolName, true)
}
```

**Step 2: Build and verify**

**Step 3: Commit**

```bash
git add NemoNotch/Notch/CompactBadge.swift
git commit -m "feat: add approval-aware badge priority in CompactBadge"
```

---

### Task 11: Final Integration Test & Cleanup

**Step 1: Clean build**

```bash
xcodebuild clean -scheme NemoNotch -configuration Debug 2>&1 | tail -2
xcodebuild -scheme NemoNotch -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED with 0 errors.

**Step 2: Manual verification checklist**

Launch the app and verify:
1. [ ] App starts without crash
2. [ ] Settings shows hook installation status
3. [ ] Click "Install Hooks" → hooks installed successfully
4. [ ] Run `cat ~/.nemonotch/hooks/hook-sender.sh` → script uses `nc -U`
5. [ ] Run `cat ~/.claude/settings.json` → includes "PermissionRequest" in hooks
6. [ ] Open Claude Code in a project → session appears in Claude tab
7. [ ] Tool execution updates status in real-time
8. [ ] Claude stop → session goes to idle
9. [ ] After 30min inactive → session auto-cleanup

**Step 3: Remove unused code**

Clean up any remaining references to:
- `NotchConstants.hookBasePort` / `hookMaxPortAttempts` (should already be removed)
- `serverPort` property references

**Step 4: Final commit**

```bash
git add -A
git commit -m "chore: Phase 1 cleanup and final integration"
```

---

## Summary

| Task | Files | Description |
|------|-------|-------------|
| 1 | `Models/SessionPhase.swift` (new) | State machine with 6 phases + transition validation |
| 2 | `Models/ChatMessage.swift` (new) | Conversation message model |
| 3 | `Models/ClaudeState.swift` (modify) | Use SessionPhase, add token tracking, message storage |
| 4 | `Services/HookServer.swift` (rewrite) | GCD Unix domain socket with request-response |
| 5 | `Services/HookInstaller.swift` (modify) | Unix socket script, add PermissionRequest hook |
| 6 | `Services/ConversationParser.swift` (new) | Incremental JSONL parser |
| 7 | `Services/InterruptWatcher.swift` (new) | Real-time file watcher for interrupts/clears |
| 8 | `Services/ClaudeCodeService.swift` (rewrite) | Wire all new components together |
| 9 | `Tabs/ClaudeTab.swift` (modify) | Socket status, tokens, permission events |
| 10 | `Notch/CompactBadge.swift` (modify) | Approval-aware badge priority |
| 11 | Various | Final integration test and cleanup |
