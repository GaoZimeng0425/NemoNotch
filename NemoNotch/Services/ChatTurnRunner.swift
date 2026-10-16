import Foundation

/// Decodes `claude -p --output-format stream-json --verbose
/// --include-partial-messages` stdout lines into bubble-relevant events.
/// Pure and unit-tested; unknown lines are ignored (forward compatibility —
/// a new CLI field must not kill the reader).
enum ChatStreamEvent: Equatable {
    /// `system/init` — carries the session id the CLI actually runs with.
    case sessionStarted(sessionId: String)
    /// A text delta of the assistant's in-flight message.
    case textDelta(String)
    /// An assistant tool call starting (`tool_use` block) — shown as a badge.
    case toolStarted(String)
    /// `result` — the turn ended. `result` text for success, error flag on
    /// failure.
    case turnCompleted(result: String?, isError: Bool)

    static func decode(_ line: Data) -> ChatStreamEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let dict = object as? [String: Any]
        else { return nil }
        switch dict["type"] as? String {
        case "system" where dict["subtype"] as? String == "init":
            if let sessionId = dict["session_id"] as? String {
                return .sessionStarted(sessionId: sessionId)
            }
            return nil
        case "stream_event":
            guard let event = dict["event"] as? [String: Any],
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return nil }
            return .textDelta(text)
        case "assistant":
            // Complete assistant message: surface tool_use starts; text is
            // already rendered from deltas.
            guard let message = dict["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]]
            else { return nil }
            for block in blocks where block["type"] as? String == "tool_use" {
                if let name = block["name"] as? String {
                    return .toolStarted(name)
                }
            }
            return nil
        case "result":
            let isError = (dict["is_error"] as? Bool) ?? false
            let text = dict["result"] as? String
            return .turnCompleted(result: isError ? (dict["result"] as? String) ?? "error" : text, isError: isError)
        default:
            return nil
        }
    }

    /// The stdin line that submits one user turn in stream-json input mode.
    static func userMessage(_ text: String) -> Data {
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}

/// Spawns one `claude -p` process per turn and streams its stdout. One turn
/// at a time; Stop is SIGINT (the CLI ends the turn cleanly); the session id
/// is fixed by the caller so hooks land on one store session and later turns
/// `--resume` it.
@MainActor
final class ChatTurnRunner {
    /// Accumulated text of the in-flight assistant message.
    private(set) var streamingText = ""
    private(set) var isRunning = false
    private var process: Process?

    struct Handlers {
        var onTextDelta: (String) -> Void = { _ in }
        var onNewMessage: () -> Void = {}
        var onToolStarted: (String) -> Void = { _ in }
        var onTurnCompleted: (String?, Bool) -> Void = { _, _ in }
    }

    private var handlers: Handlers?

    /// Launch one turn. `resume` continues an existing session id instead of
    /// minting a new one.
    func run(prompt: String, sessionId: String, resume: Bool, handlers: Handlers) {
        guard !isRunning else { return }
        self.handlers = handlers
        streamingText = ""
        isRunning = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // Login shells put ~/.bun/bin on PATH; a GUI-spawned process does not
        // have it — resolve the common locations rather than requiring PATH.
        let claudeURL = Self.locateClaude() ?? URL(fileURLWithPath: "/opt/homebrew/bin/claude")
        process.arguments = [
            claudeURL.path, "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose", "--include-partial-messages",
        ] + (resume ? ["--resume", sessionId] : ["--session-id", sessionId])
        process.environment = ProcessInfo.processInfo.environment
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // SIGINT on stop must reach claude, not get the process group killed.
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.process === process else { return }
                self.process = nil
                isRunning = false
                self.handlers?.onTurnCompleted(nil, false)
            }
        }

        do {
            try process.run()
        } catch {
            LogService.error("ChatTurnRunner spawn failed: \(error)", category: "ChatBubble")
            isRunning = false
            handlers.onTurnCompleted("claude 启动失败:\(error.localizedDescription)", true)
            return
        }
        self.process = process
        LogService.info("Chat turn started (resume=\(resume))", category: "ChatBubble")

        // Submit the prompt, then keep stdin open until the turn ends —
        // closing it after one message is also valid, but a kept pipe lets
        // claude flush its init before the input is read.
        try? stdin.fileHandleForWriting.write(contentsOf: ChatStreamEvent.userMessage(prompt))
        stdin.fileHandleForWriting.closeFile()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                if let event = ChatStreamEvent.decode(Data(line)) {
                    Task { @MainActor [weak self] in
                        self?.apply(event)
                    }
                }
            }
        }
    }

    private func apply(_ event: ChatStreamEvent) {
        switch event {
        case .sessionStarted:
            break
        case let .textDelta(delta):
            if streamingText.isEmpty {
                handlers?.onNewMessage()
            }
            streamingText += delta
            handlers?.onTextDelta(streamingText)
        case let .toolStarted(name):
            handlers?.onToolStarted(name)
        case let .turnCompleted(result, isError):
            process?.terminate()
            process = nil
            isRunning = false
            handlers?.onTurnCompleted(result, isError)
        }
    }

    /// SIGINT — claude ends the turn cleanly; the terminationHandler reports
    /// completion.
    func stop() {
        guard let process, isRunning else { return }
        LogService.info("Chat turn stopped by user", category: "ChatBubble")
        process.interrupt()
    }

    /// GUI processes lack the login-shell PATH; look where installers put the
    /// binary (first hit wins).
    nonisolated static func locateClaude() -> URL? {
        let candidates = [
            NSHomeDirectory() + "/.bun/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
