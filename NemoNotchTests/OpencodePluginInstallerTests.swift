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
