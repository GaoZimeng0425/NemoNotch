import Foundation

enum HookTarget {
    case claude
    case gemini
    case zcode

    var settingsPath: String {
        switch self {
        case .claude: return NSHomeDirectory() + "/.claude/settings.json"
        case .gemini: return NSHomeDirectory() + "/.gemini/settings.json"
        case .zcode: return NSHomeDirectory() + "/.zcode/cli/config.json"
        }
    }

    var hookEvents: [String] {
        switch self {
        case .claude: return [
                "PreToolUse", "PostToolUse", "Stop", "SessionStart",
                "SessionEnd", "Notification", "UserPromptSubmit", "PermissionRequest",
            ]
        case .gemini: return [
                "SessionStart", "SessionEnd", "Notification",
                "BeforeAgent", "AfterAgent", "BeforeTool", "AfterTool",
            ]
        case .zcode: return [
                "SessionStart", "UserPromptSubmit", "PreToolUse",
                "PostToolUse", "PostToolUseFailure", "Stop",
            ]
        }
    }

    /// zcode nests hooks under `hooks.events.<Event>` with a sibling
    /// `hooks.enabled = true` flag, unlike Claude/Gemini's flat `hooks.<Event>`.
    var usesNestedEventsContainer: Bool {
        switch self {
        case .zcode: return true
        case .claude, .gemini: return false
        }
    }

    /// The `matcher` string written on each hook entry. zcode's matcher is a
    /// case-sensitive regular expression (NOT a glob) tested against the tool
    /// name / event value, and a `>=1 character` rule rejects the entire hooks
    /// config when any matcher is empty. `"*"` is an *invalid* regex (a quantifier
    /// with no preceding atom) that silently never matches — so zcode must use
    /// `".*"` to match all tools. Claude/Gemini accept (and historically used) `""`.
    var defaultMatcher: String {
        switch self {
        case .zcode: return ".*"
        case .claude, .gemini: return ""
        }
    }

    /// Whether this target's hook runner requires `type: "process"` entries.
    /// zcode v2's hook parser only collects hooks whose inner entry is
    /// `type: "process"` and runs `command` directly via `child_process.spawn`
    /// (no shell) — entries typed `type: "command"` are silently dropped, so a
    /// "command" hook is registered but never fires. Claude/Gemini use
    /// `type: "command"`, executed through a shell (so `~` expands).
    var requiresProcessHookType: Bool {
        switch self {
        case .zcode: return true
        case .claude, .gemini: return false
        }
    }
}

enum HookInstallerError: LocalizedError {
    /// 已存在的 CLI 配置文件解析失败:拒绝在其上继续安装写入。
    case existingSettingsUnreadable(path: String)

    var errorDescription: String? {
        switch self {
        case let .existingSettingsUnreadable(path):
            return "Existing \(path) could not be parsed as JSON; refusing to overwrite it"
        }
    }
}

enum HookInstaller {
    private static let hookScriptDir = NSHomeDirectory() + "/.NemoNotch/hooks"
    private static let hookScriptPath = hookScriptDir + "/hook-sender.sh"

    private static let scriptVersion = "# version: 15"

    /// The command string for `target`. Claude/Gemini run hooks through a shell
    /// so `~` expands; zcode's `type:"process"` runs `spawn(command, args)` with
    /// no shell, so it needs the absolute home path.
    private static func hookCommand(for target: HookTarget) -> String {
        switch target {
        case .zcode: return hookScriptPath // absolute, e.g. /Users/.../.NemoNotch/hooks/hook-sender.sh
        case .claude, .gemini: return "~/.NemoNotch/hooks/hook-sender.sh"
        }
    }

    /// Case-insensitive suffix match so we recognize both the older
    /// "~/.nemonotch/hooks/hook-sender.sh" and the current
    /// "~/.NemoNotch/hooks/hook-sender.sh" forms as ours.
    private static func isOurHookCommand(_ command: String?) -> Bool {
        guard let command else { return false }
        return command.lowercased().hasSuffix("nemonotch/hooks/hook-sender.sh")
    }

    /// Reads the event→entries map for `target`, unwrapping zcode's nested
    /// `hooks.events` container.
    static func readEvents(_ settings: [String: Any], target: HookTarget) -> [String: Any] {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        if target.usesNestedEventsContainer {
            return hooks["events"] as? [String: Any] ?? [:]
        }
        return hooks
    }

    /// Writes the event→entries map back, re-wrapping zcode's nested container
    /// (and setting `enabled = true`). Drops the `hooks` key when empty.
    static func writeEvents(_ events: [String: Any], into settings: inout [String: Any], target: HookTarget) {
        if target.usesNestedEventsContainer {
            var hooks = settings["hooks"] as? [String: Any] ?? [:]
            if events.isEmpty {
                hooks.removeValue(forKey: "events")
                hooks.removeValue(forKey: "enabled")
            } else {
                hooks["events"] = events
                hooks["enabled"] = true
            }
            if hooks.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = hooks
            }
        } else {
            if events.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = events
            }
        }
    }

    /// Pure install transform: strips all our old entries from every event, then
    /// registers `target.hookEvents` pointing at `command`.
    static func applyInstall(_ settings: [String: Any], target: HookTarget, command: String) -> [String: Any] {
        var out = settings
        var events = readEvents(out, target: target)

        for (event, entries) in events {
            if var eventEntries = entries as? [[String: Any]] {
                eventEntries.removeAll { entry in
                    guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                    return inner.contains { isOurHookCommand($0["command"] as? String) }
                }
                if eventEntries.isEmpty {
                    events.removeValue(forKey: event)
                } else {
                    events[event] = eventEntries
                }
            }
        }

        // zcode v2's hook parser only collects `type:"process"` entries (it
        // silently drops `type:"command"`); Claude/Gemini use `type:"command"`.
        // The command path form also differs: zcode runs `spawn(command, args)`
        // with no shell, so the caller must pass an absolute path for zcode,
        // whereas Claude/Gemini run through a shell so `~` expands.
        var innerHook: [String: Any] = [
            "type": target.requiresProcessHookType ? "process" : "command",
            "command": command,
        ]
        if target.requiresProcessHookType {
            innerHook["timeoutMs"] = 30_000
        }

        let hookEntry: [String: Any] = [
            "matcher": target.defaultMatcher,
            "hooks": [innerHook],
        ]
        for event in target.hookEvents {
            var entries = events[event] as? [[String: Any]] ?? []
            entries.append(hookEntry)
            events[event] = entries
        }

        writeEvents(events, into: &out, target: target)
        return out
    }

    /// Pure uninstall transform: removes only our entries from `target.hookEvents`.
    static func applyUninstall(_ settings: [String: Any], target: HookTarget) -> [String: Any] {
        var out = settings
        var events = readEvents(out, target: target)
        for event in target.hookEvents {
            guard var entries = events[event] as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                return inner.contains { isOurHookCommand($0["command"] as? String) }
            }
            if entries.isEmpty {
                events.removeValue(forKey: event)
            } else {
                events[event] = entries
            }
        }
        writeEvents(events, into: &out, target: target)
        return out
    }

    /// Pure detection: any of `target.hookEvents` holds one of our entries.
    static func detectInstalled(_ settings: [String: Any], target: HookTarget) -> Bool {
        let events = readEvents(settings, target: target)
        for event in target.hookEvents {
            if let entries = events[event] as? [[String: Any]],
               entries.contains(where: { entry in
                   guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
                   return inner.contains { isOurHookCommand($0["command"] as? String) }
               }) {
                return true
            }
        }
        return false
    }

    static func isInstalled(_ target: HookTarget) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target.settingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return detectInstalled(json, target: target)
    }

    static func install(_ target: HookTarget) throws {
        try ensureScriptExists()
        var settings: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: target.settingsPath) {
            // 既有配置必须先成功解析才能继续:解析失败(半写损坏、手写语法错)
            // 时继续安装会以"仅含我们 hooks 的空配置"整体覆盖,用户其余全部
            // 设置被静默清空。拒绝写入并抛错,先让用户修好该文件。
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: target.settingsPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HookInstallerError.existingSettingsUnreadable(path: target.settingsPath)
            }
            settings = json
        }
        settings = applyInstall(settings, target: target, command: hookCommand(for: target))
        try writeSettings(settings, to: target)
    }

    static func uninstall(_ target: HookTarget) throws {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target.settingsPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["hooks"] is [String: Any] else {
            return
        }
        let settings = applyUninstall(json, target: target)
        try writeSettings(settings, to: target)
    }

    static func ensureScriptExists() throws {
        let scriptURL = URL(fileURLWithPath: hookScriptPath)
        let port = NotchConstants.hookServerPort
        let portMarker = "# port: \(port)"

        // Re-write if version OR port has changed (HookServer may have fallen
        // back to a non-default port; we need the script to match).
        if FileManager.default.fileExists(atPath: hookScriptPath),
           let contents = try? String(contentsOf: scriptURL, encoding: .utf8),
           contents.contains(scriptVersion),
           contents.contains(portMarker) {
            return
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: hookScriptDir),
            withIntermediateDirectories: true
        )

        let script = """
        #!/bin/bash
        \(scriptVersion)
        \(portMarker)
        # hook-sender.sh — forwards Claude Code / Gemini CLI / zcode hook events to NemoNotch over TCP loopback.
        # Bails instantly when the desktop server isn't running, so the CLI never blocks waiting for nc.
        URL_BASE="http://127.0.0.1:\(port)"
        curl -s --connect-timeout 0.3 "$URL_BASE/health" >/dev/null 2>&1 || exit 0

        # Detect which CLI invoked this hook
        if [ -n "$GEMINI_SESSION_ID" ]; then
            CLI_SOURCE="gemini"
        elif [ -n "$ZCODE_SESSION_ID" ]; then
            CLI_SOURCE="zcode"
        elif [ -n "$CLAUDE_SESSION_ID" ]; then
            CLI_SOURCE="claude"
        else
            PARENT_PID=$PPID
            COMMAND_LINE=$(ps -o args= -p "$PARENT_PID" 2>/dev/null || echo "")
            if echo "$COMMAND_LINE" | grep -q "gemini"; then
                CLI_SOURCE="gemini"
            elif echo "$COMMAND_LINE" | grep -qi "zcode"; then
                CLI_SOURCE="zcode"
            elif echo "$COMMAND_LINE" | grep -q "claude"; then
                CLI_SOURCE="claude"
            else
                PARENT=$(ps -o comm= -p "$PARENT_PID" 2>/dev/null || echo "")
                case "$PARENT" in
                    *gemini*)  CLI_SOURCE="gemini" ;;
                    *[zZ]code*) CLI_SOURCE="zcode" ;;
                    *claude*)  CLI_SOURCE="claude" ;;
                    *)         CLI_SOURCE="unknown" ;;
                esac
            fi
        fi

        INPUT=$(cat 2>/dev/null || echo '{}')

        # Inject cli_source into the JSON payload. cli_pid (bash's $PPID, i.e.
        # the CLI process itself) lets the notch walk up to the hosting
        # terminal/IDE app for session jumps; the isdigit guard keeps a bad
        # value from raising inside python and losing the cli_source tagging
        # too (the except-path re-emits the ORIGINAL payload untagged).
        if command -v python3 &>/dev/null; then
            INPUT=$(echo "$INPUT" | python3 -c "
        import sys, json
        try:
            d = json.load(sys.stdin)
            d['cli_source'] = '$CLI_SOURCE'
            if '$PPID'.isdigit():
                d['cli_pid'] = int('$PPID')
            json.dump(d, sys.stdout)
        except Exception:
            sys.exit(1)
        " 2>/dev/null || echo "$INPUT")
        fi

        EVENT_NAME=$(echo "$INPUT" | grep -o '"hook_event_name":"[^"]*"' | head -1 | cut -d'"' -f4)

        if [ "$EVENT_NAME" = "PermissionRequest" ]; then
            # Blocking: hold the connection until NemoNotch returns a decision (up to 120s).
            # Run curl in background so the script can clean it up if Claude Code kills us.
            TMPFILE=$(mktemp /tmp/nemonotch-hook.XXXXXX)
            curl -s -X POST -H "Content-Type: application/json" -d "$INPUT" \\
                "$URL_BASE/hook" --connect-timeout 2 --max-time 120 >"$TMPFILE" 2>/dev/null &
            CURL_PID=$!
            trap 'kill $CURL_PID 2>/dev/null; rm -f "$TMPFILE"; exit 0' TERM HUP INT
            wait $CURL_PID
            BODY=$(cat "$TMPFILE")
            rm -f "$TMPFILE"
            [ -n "$BODY" ] && echo "$BODY"
            exit 0
        else
            curl -s -X POST -H "Content-Type: application/json" -d "$INPUT" \\
                "$URL_BASE/hook" --connect-timeout 1 --max-time 2 >/dev/null 2>&1 || true
            exit 0
        fi
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
        // 覆盖前留备份 + 原子写:进程在写入中途崩溃/断电不会留下截断的半个
        // JSON;即使写出的内容有误,用户也能从 .bak 找回其余配置。
        if FileManager.default.fileExists(atPath: target.settingsPath) {
            let backupPath = target.settingsPath + ".nemonotch.bak"
            try? FileManager.default.removeItem(atPath: backupPath)
            try? FileManager.default.copyItem(atPath: target.settingsPath, toPath: backupPath)
        }
        try data.write(to: URL(fileURLWithPath: target.settingsPath), options: .atomic)
    }
}
