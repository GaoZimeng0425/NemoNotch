import Foundation
@testable import NemoNotch
import Testing

@MainActor
struct ZcodeHookInstallerTests {
    private let cmdSuffix = "nemonotch/hooks/hook-sender.sh"

    @Test func installWrapsHooksInNestedEventsContainerWithEnabledFlag() throws {
        var settings: [String: Any] = ["mcp": ["servers": [:]], "plugins": ["x": true]]
        settings = HookInstaller.applyInstall(settings, target: .zcode, command: "~/\(cmdSuffix)")

        let hooks = try #require(settings["hooks"] as? [String: Any])
        #expect(hooks["enabled"] as? Bool == true)
        let events = try #require(hooks["events"] as? [String: Any])
        #expect(events["SessionStart"] != nil)
        #expect(events["Stop"] != nil)
        // Foreign top-level keys are preserved.
        #expect(settings["mcp"] != nil)
        #expect(settings["plugins"] != nil)
    }

    @Test func zcodeEntriesUseValidMatchAllMatcher() throws {
        // zcode's matcher is a case-sensitive *regular expression* (not a glob),
        // and a `>=1 character` rule rejects the whole config when empty.
        // `"*"` is an INVALID regex ("nothing to repeat") that silently never
        // matches — only `".*"` is a valid match-all. Guard against regression.
        var settings: [String: Any] = [:]
        settings = HookInstaller.applyInstall(settings, target: .zcode, command: "~/\(cmdSuffix)")
        let events = try #require((settings["hooks"] as? [String: Any])?["events"] as? [String: Any])
        for (event, raw) in events {
            let entries = try #require(raw as? [[String: Any]], "\(event) entries")
            for entry in entries {
                let matcher = try #require(entry["matcher"] as? String, "\(event) matcher")
                #expect(matcher == ".*", "\(event) matcher must be '.*' (got '\(matcher)')")
            }
        }
    }

    @Test func zcodeEntriesUseProcessTypeNotCommand() throws {
        // zcode v2's hook parser collects ONLY inner entries where
        // `type === "process"`; it silently drops `type:"command"`. So every
        // zcode entry must be process-typed (with timeoutMs) or it never fires.
        var settings: [String: Any] = [:]
        settings = HookInstaller.applyInstall(settings, target: .zcode, command: "~/\(cmdSuffix)")
        let events = try #require((settings["hooks"] as? [String: Any])?["events"] as? [String: Any])
        for (event, raw) in events {
            let entries = try #require(raw as? [[String: Any]], "\(event) entries")
            for entry in entries {
                let inner = try #require(entry["hooks"] as? [[String: Any]], "\(event) inner hooks")
                for h in inner {
                    let type = try #require(h["type"] as? String, "\(event) hook type")
                    #expect(type == "process", "\(event) hook must be type 'process' for zcode (got '\(type)')")
                    #expect(h["timeoutMs"] != nil, "\(event) process hook should carry timeoutMs")
                }
            }
        }
    }

    @Test func claudeEntriesUseCommandType() throws {
        // Claude runs hooks through a shell via `type:"command"` (the zcode-only
        // "process" requirement must NOT leak into Claude/Gemini entries).
        var settings: [String: Any] = [:]
        settings = HookInstaller.applyInstall(settings, target: .claude, command: "~/\(cmdSuffix)")
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let entries = try #require(hooks["PreToolUse"] as? [[String: Any]])
        let inner = try #require(entries.first?["hooks"] as? [[String: Any]])
        let type = try #require(inner.first?["type"] as? String)
        #expect(type == "command")
        #expect(inner.first?["timeoutMs"] == nil)
    }

    @Test func claudeEntriesKeepEmptyMatcher() throws {
        // Claude's format is unchanged: entries carry an empty match-all matcher.
        var settings: [String: Any] = [:]
        settings = HookInstaller.applyInstall(settings, target: .claude, command: "~/\(cmdSuffix)")
        let hooks = try #require(settings["hooks"] as? [String: Any])
        let entries = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(entries.first?["matcher"] as? String == "")
    }

    @Test func isInstalledDetectsNestedEntries() {
        var settings: [String: Any] = [:]
        settings = HookInstaller.applyInstall(settings, target: .zcode, command: "~/\(cmdSuffix)")
        #expect(HookInstaller.detectInstalled(settings, target: .zcode) == true)
    }

    @Test func uninstallRemovesOnlyOurEntriesAndKeepsForeign() {
        // Pre-existing foreign hook the user added.
        let foreign: [String: Any] = ["hooks": [["type": "command", "command": "bash /me/foo.sh"]]]
        var settings: [String: Any] = [
            "hooks": ["enabled": true, "events": ["Stop": [foreign]]],
            "mcp": ["servers": [:]],
        ]
        settings = HookInstaller.applyInstall(settings, target: .zcode, command: "~/\(cmdSuffix)")
        settings = HookInstaller.applyUninstall(settings, target: .zcode)

        #expect(HookInstaller.detectInstalled(settings, target: .zcode) == false)
        // Foreign Stop hook survives.
        let events = (settings["hooks"] as? [String: Any])?["events"] as? [String: Any]
        let stop = events?["Stop"] as? [[String: Any]]
        #expect(stop?.count == 1)
        #expect(settings["mcp"] != nil)
    }

    @Test func flatTargetInstallWritesFlatHooksAndUninstallClears() throws {
        var settings: [String: Any] = [:]
        settings = HookInstaller.applyInstall(settings, target: .claude, command: "~/\(cmdSuffix)")
        let hooks = try #require(settings["hooks"] as? [String: Any])
        // Flat target: entries live directly under hooks.<Event>, NOT nested under events/enabled.
        #expect(hooks["events"] == nil)
        #expect(hooks["enabled"] == nil)
        #expect(hooks["PreToolUse"] != nil)
        #expect(HookInstaller.detectInstalled(settings, target: .claude) == true)

        settings = HookInstaller.applyUninstall(settings, target: .claude)
        #expect(HookInstaller.detectInstalled(settings, target: .claude) == false)
        #expect(settings["hooks"] == nil) // hooks key removed when empty
    }
}
