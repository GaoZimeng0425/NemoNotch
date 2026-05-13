import Foundation

enum HermesHookInstaller {
    private static let hermesDir = NSHomeDirectory() + "/.hermes"
    private static let scriptDir = NSHomeDirectory() + "/.nemonotch/hooks"
    private static let scriptPath = scriptDir + "/hermes-hook-sender.sh"
    private static let scriptCommand = "~/.nemonotch/hooks/hermes-hook-sender.sh"
    private static let socketPath = NotchConstants.hookSocketPath
    private static let marker = "# nemonotch-hermes-hook"

    private static let hookEvents = [
        "pre_llm_call",
        "post_llm_call",
        "pre_tool_call",
        "post_tool_call",
        "on_session_start",
        "on_session_end",
    ]

    // MARK: - Public API

    static var isInstalled: Bool {
        // Check all possible config locations
        for path in allConfigPaths() {
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               content.contains("nemonotch/hooks/hermes-hook-sender.sh") {
                return true
            }
        }
        return false
    }

    static func install() throws {
        try ensureScriptExists()
        // Patch both root and profile configs
        for path in allConfigPaths() {
            try patchConfig(at: path, install: true)
        }
        LogService.info("Hermes shell hooks installed", category: "HermesHookInstaller")
    }

    static func uninstall() throws {
        for path in allConfigPaths() {
            try? patchConfig(at: path, install: false)
        }
        LogService.info("Hermes shell hooks uninstalled", category: "HermesHookInstaller")
    }

    // MARK: - Config Path Resolution

    /// All config.yaml paths: root (default profile) + every named profile.
    private static func allConfigPaths() -> [String] {
        var paths = [hermesDir + "/config.yaml"]

        // All named profiles
        let profilesDir = hermesDir + "/profiles"
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) {
            for name in contents {
                let configPath = profilesDir + "/" + name + "/config.yaml"
                if FileManager.default.fileExists(atPath: configPath) {
                    paths.append(configPath)
                }
            }
        }

        return paths
    }

    // MARK: - Script

    private static func ensureScriptExists() throws {
        let url = URL(fileURLWithPath: scriptPath)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: scriptDir),
            withIntermediateDirectories: true
        )

        let script = """
        #!/bin/bash
        \(marker)
        SOCKET="\(socketPath)"
        [ -S "$SOCKET" ] || exit 0

        INPUT=$(cat 2>/dev/null || echo '{}')

        # Inject cli_source into the JSON payload
        if command -v python3 &>/dev/null; then
            INPUT=$(echo "$INPUT" | python3 -c "
        import sys, json
        try:
            d = json.load(sys.stdin)
            d['cli_source'] = 'hermes'
            json.dump(d, sys.stdout)
        except Exception:
            sys.exit(1)
        " 2>/dev/null || echo "$INPUT")
        fi

        echo "$INPUT" | nc -U -w 1 "$SOCKET" 2>/dev/null || true
        printf '{}\\n'
        exit 0
        """

        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptPath
        )
    }

    // MARK: - YAML Patching

    private static func patchConfig(at path: String, install: Bool) throws {
        var content: String = if let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            existing
        } else {
            ""
        }

        // Ensure config dir exists
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if install {
            content = addHooksBlock(to: content)
        } else {
            content = removeHooksBlock(from: content)
        }

        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private static func addHooksBlock(to content: String) -> String {
        var lines = content.components(separatedBy: "\n")

        // Remove existing nemonotch hooks block first
        lines = removeNemonotchLines(from: lines)

        // Build our hook entries
        let ourLines = hookEvents.flatMap { event -> [String] in
            [
                "  \(event):",
                "    - command: \"\(scriptCommand)\"",
            ]
        }

        // Find existing hooks: line (handles "hooks:", "hooks: {}", "hooks: []")
        if let hooksIdx = lines
            .firstIndex(where: { $0.range(of: "^[^#]*hooks:", options: .regularExpression) != nil }) {
            // Replace the hooks line and insert our entries
            let hookLine = lines[hooksIdx]
            if hookLine.contains("{}") || hookLine.contains("[]") {
                // Inline empty dict/list — replace with our block
                lines[hooksIdx] = "hooks:"
                lines.insert(contentsOf: ourLines, at: hooksIdx + 1)
            } else {
                // "hooks:" already exists as block — insert entries after it
                lines.insert(contentsOf: ourLines, at: hooksIdx + 1)
            }
        } else {
            // No hooks section — append at the end
            if lines.last?.isEmpty == true { lines.removeLast() }
            lines.append("hooks:")
            lines.append(contentsOf: ourLines)
        }

        // Update or add hooks_auto_accept
        if let idx = lines
            .firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("hooks_auto_accept:") }) {
            lines[idx] = "hooks_auto_accept: true"
        } else {
            lines.append("hooks_auto_accept: true")
        }

        return lines.joined(separator: "\n")
    }

    private static func removeHooksBlock(from content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        lines = removeNemonotchLines(from: lines)
        return lines.joined(separator: "\n")
    }

    /// Remove all lines referencing our hook script, plus empty event blocks left behind.
    private static func removeNemonotchLines(from lines: [String]) -> [String] {
        var result = lines

        // Remove lines containing our script path
        result.removeAll { line in
            line.contains("nemonotch/hooks/hermes-hook-sender.sh")
        }

        // Remove empty event entries (e.g. "  pre_llm_call:" with no children)
        // We look for our known event names that now have no following indented lines
        var cleaned: [String] = []
        for (i, line) in result.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isOurEvent = hookEvents.contains(where: { trimmed == $0 + ":" })
            if isOurEvent {
                // Check if next line is still indented (belongs to another hook)
                let nextIndent = result[safe: i + 1]?.prefix(while: { $0 == " " }).count ?? 0
                let currentIndent = line.prefix(while: { $0 == " " }).count
                if nextIndent <= currentIndent {
                    // Empty block — skip this line
                    continue
                }
            }
            cleaned.append(line)
        }

        // Remove hooks_auto_accept if it was set by us
        cleaned.removeAll { $0.trimmingCharacters(in: .whitespaces) == "hooks_auto_accept: true" }

        // Remove "hooks:" if it's now empty
        if let hooksIdx = cleaned.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "hooks:" }) {
            let nextIndent = cleaned[safe: hooksIdx + 1]?.prefix(while: { $0 == " " }).count ?? 0
            if nextIndent == 0 || hooksIdx == cleaned.count - 1 {
                cleaned.remove(at: hooksIdx)
            }
        }

        return cleaned
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
