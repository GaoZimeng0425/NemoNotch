@testable import NemoNotch
import Testing

struct OpencodePluginInstallerTests {
    @Test func pluginSourceEmbedsPortAndMarker() {
        let src = OpencodePluginInstaller.pluginSource(port: 47321)
        #expect(src.contains("nemonotch-opencode-plugin"))
        #expect(src.contains("http://127.0.0.1:47321"))
        #expect(src.contains("\"cli_source\": \"opencode\"") || src.contains("cli_source: \"opencode\""))
    }

    @Test func pluginSourceWiresAllLifecycleHooks() {
        let src = OpencodePluginInstaller.pluginSource(port: 1)
        #expect(src.contains("UserPromptSubmit"))
        #expect(src.contains("PreToolUse"))
        #expect(src.contains("PostToolUse"))
        #expect(src.contains("Stop"))
        #expect(src.contains("permission.ask"))
        #expect(src.contains("session.idle"))
        #expect(src.contains("PreCompact"))
        #expect(src.contains("session.compacted"))
    }
}

extension OpencodePluginInstallerTests {
    @Test func pluginV3HoldsApprovalBridgeAndAppliesViaClient() {
        let src = OpencodePluginInstaller.pluginSource(port: 1)
        // The held bridge: a PermissionRequest POST without a short timeout
        #expect(src.contains("hook_event_name: \"PermissionRequest\""))
        #expect(src.contains("AbortController"))
        // Decisions are applied through opencode's own client API
        #expect(src.contains("postSessionIdPermissionsPermissionId"))
        // Only once/reject are ever sent — never "always"
        #expect(src.contains("\"once\""))
        #expect(src.contains("\"reject\""))
        #expect(!src.contains("\"always\""))
        // Timeout must NOT decide (opencode's TUI stays in charge)
        #expect(src.contains("!== \"timeout\""))
        // The TUI answering first drops the held copy
        #expect(src.contains("permission.replied"))
        // The entry captures the plugin input's client (1.x apply path)
        #expect(src.contains("input.client"))
    }
}
