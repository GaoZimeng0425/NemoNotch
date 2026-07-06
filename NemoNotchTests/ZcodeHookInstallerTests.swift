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
}
