import Foundation

enum HookTarget {
    case claude
    case gemini

    var settingsPath: String {
        switch self {
        case .claude: return NSHomeDirectory() + "/.claude/settings.json"
        case .gemini: return NSHomeDirectory() + "/.gemini/settings.json"
        }
    }

    var hookEvents: [String] {
        switch self {
        case .claude: return [
            "PreToolUse", "PostToolUse", "Stop", "SessionStart",
            "SessionEnd", "Notification", "UserPromptSubmit", "PermissionRequest",
        ]
        case .gemini: return [
            "PreToolUse", "PostToolUse", "Stop", "SessionStart",
            "SessionEnd", "Notification", "UserPromptSubmit",
        ]
        }
    }
}

enum HookInstaller {
    private static let hookScriptDir = NSHomeDirectory() + "/.nemonotch/hooks"
    private static let hookScriptPath = hookScriptDir + "/hook-sender.sh"
    private static var hookCommand: String { "~/.nemonotch/hooks/hook-sender.sh" }
    private static let socketPath = NotchConstants.hookSocketPath

    private static let scriptVersion = "# version: 5"

    static func isInstalled(_ target: HookTarget) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target.settingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else {
            return false
        }
        for event in target.hookEvents {
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

    static func install(_ target: HookTarget) throws {
        try ensureScriptExists()

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: target.settingsPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let hookEntry: [String: Any] = [
            "matcher": "",
            "hooks": [["type": "command", "command": hookCommand]],
        ]

        for event in target.hookEvents {
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
        try writeSettings(settings, to: target)
    }

    static func uninstall(_ target: HookTarget) throws {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target.settingsPath)),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else {
            return
        }

        for event in target.hookEvents {
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

        try writeSettings(settings, to: target)
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

        let script = """
        #!/bin/bash
        \(scriptVersion)
        SOCKET="\(socketPath)"
        [ -S "$SOCKET" ] || exit 0

        # Detect which CLI invoked this hook
        PARENT=$(ps -o comm= -p $PPID 2>/dev/null || echo "")
        case "$PARENT" in
            *gemini*)  CLI_SOURCE="gemini" ;;
            *claude*)  CLI_SOURCE="claude" ;;
            *)         CLI_SOURCE="unknown" ;;
        esac

        INPUT=$(cat 2>/dev/null || echo '{}')

        # Inject cli_source into the JSON payload
        if command -v python3 &>/dev/null; then
            INPUT=$(echo "$INPUT" | python3 -c "
        import sys, json
        d = json.load(sys.stdin)
        d['cli_source'] = '$CLI_SOURCE'
        json.dump(d, sys.stdout)
        " 2>/dev/null || echo "$INPUT")
        fi

        if echo "$INPUT" | grep -q '"PermissionRequest"'; then
            echo "$INPUT" | nc -U -w 120 "$SOCKET" 2>/dev/null
        else
            echo "$INPUT" | nc -U -w 1 "$SOCKET" 2>/dev/null || true
        fi
        exit 0
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hookScriptPath
        )
    }

    private static func writeSettings(_ settings: [String: Any], to target: HookTarget) throws {
        let dir = (target.settingsPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: target.settingsPath))
    }
}
