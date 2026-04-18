import Foundation

enum HookInstaller {
    private static let claudeSettingsPath = NSHomeDirectory() + "/.claude/settings.json"
    private static let hookScriptDir = NSHomeDirectory() + "/.nemonotch/hooks"
    private static let hookScriptPath = hookScriptDir + "/hook-sender.sh"
    private static var hookCommand: String { "~/.nemonotch/hooks/hook-sender.sh" }

    private static let hookEvents = [
        "PreToolUse",
        "PostToolUse",
        "Stop",
        "SessionStart",
        "SessionEnd",
        "Notification",
        "UserPromptSubmit",
    ]

    private static let scriptVersion = "# version: 2"

    static var currentPort: UInt16 {
        UInt16(UserDefaults.standard.integer(forKey: "hookServerPort"))
    }

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

    static func install(port: UInt16) throws {
        UserDefaults.standard.set(Int(port), forKey: "hookServerPort")
        try ensureScriptExists(port: port)

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

    static func ensureScriptExists(port: UInt16) throws {
        let scriptURL = URL(fileURLWithPath: hookScriptPath)

        if FileManager.default.fileExists(atPath: hookScriptPath),
           let contents = try? String(contentsOf: scriptURL, encoding: .utf8),
           contents.contains(scriptVersion),
           contents.contains("localhost:\(port)") {
            return
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: hookScriptDir),
            withIntermediateDirectories: true
        )

        let script = """
        #!/bin/bash
        \(scriptVersion)
        curl -s --connect-timeout 0.3 "http://localhost:\(port)/health" >/dev/null 2>&1 || exit 0
        INPUT=$(cat 2>/dev/null || echo '{}')
        curl -s -X POST -H "Content-Type: application/json" -d "$INPUT" \\
          "http://localhost:\(port)/hook" \\
          --connect-timeout 1 --max-time 2 2>/dev/null || true
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
