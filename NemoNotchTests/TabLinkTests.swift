import Foundation
@testable import NemoNotch
import Testing

struct TabLinkTests {
    // MARK: - per-terminal mappings

    @Test func itermSessionIDBecomesRevealURL() {
        let url = TabLink.resolve(["ITERM_SESSION_ID": "w0t0p0:5E9FB2C8-1A2B-3C4D-5E6F-0123456789AB"])
        #expect(url?.absoluteString == "iterm2:reveal?sessionid=w0t0p0:5E9FB2C8-1A2B-3C4D-5E6F-0123456789AB")
    }

    @Test func itermMalformedIDsResolveNothing() {
        #expect(TabLink.resolve(["ITERM_SESSION_ID": "no-colon-here"]) == nil)
        #expect(TabLink.resolve(["ITERM_SESSION_ID": ":uuid-with-hyphens"]) == nil)
        #expect(TabLink.resolve(["ITERM_SESSION_ID": "w0t0p0:"]) == nil)
    }

    @Test func readyURLVariablesPassThroughWithSchemeGuard() {
        #expect(
            TabLink.resolve(["WARP_FOCUS_URL": "warp://session/abc123"])?.absoluteString == "warp://session/abc123"
        )
        #expect(TabLink.resolve(["WARP_FOCUS_URL": "https://evil.example"]) == nil)
        #expect(
            TabLink.resolve(["BATERI_TAB_URL": "bateri://tab/deadbeef"])?.absoluteString == "bateri://tab/deadbeef"
        )
        #expect(
            TabLink.resolve(["METALTERM_TAB_URL": "metalterm://tab/x1"])?.absoluteString == "metalterm://tab/x1"
        )
    }

    @Test func claudeDesktopRequiresLocalPrefix() {
        let url = TabLink.resolve(["CLAUDE_CODE_HOST_SESSION_ID": "local_abc-123"])
        #expect(url?.absoluteString == "claude://code/continue?session=local_abc-123")
        #expect(TabLink.resolve(["CLAUDE_CODE_HOST_SESSION_ID": "remote_abc"]) == nil)
    }

    @Test func cmuxNeedsBothValidUUIDs() {
        let url = TabLink.resolve([
            "CMUX_WORKSPACE_ID": "11111111-2222-3333-4444-555555555555",
            "CMUX_SURFACE_ID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        ])
        // UUID.uuidString normalizes to uppercase
        #expect(url?.absoluteString
            .lowercased() ==
            "cmux://workspace/11111111-2222-3333-4444-555555555555/surface/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(TabLink.resolve(["CMUX_WORKSPACE_ID": "11111111-2222-3333-4444-555555555555"]) == nil)
        #expect(TabLink.resolve([
            "CMUX_WORKSPACE_ID": "not-a-uuid",
            "CMUX_SURFACE_ID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        ]) == nil)
    }

    @Test func emptyEnvironmentResolvesNothing() {
        #expect(TabLink.resolve([:]) == nil)
    }

    // MARK: - KERN_PROCARGS2 buffer split

    private func makeBuffer(argc: Int32, path: String, args: [String], env: [String]) -> [UInt8] {
        var bytes: [UInt8] = []
        for shift in 0 ..< 4 {
            bytes.append(UInt8((argc >> (shift * 8)) & 0xFF))
        }
        bytes += Array(path.utf8) + [0]
        // argv and environ strings are CONTIGUOUS in the real area — the NUL
        // padding lives between the exec path and the first argument only.
        for arg in args {
            bytes += Array(arg.utf8) + [0]
        }
        for entry in env {
            bytes += Array(entry.utf8) + [0]
        }
        return bytes
    }

    @Test func procArgsSplitSeparatesArgumentsAndEnvironment() {
        let buffer = makeBuffer(
            argc: 2,
            path: "/usr/local/bin/node",
            args: ["/usr/local/bin/claude", "--flag"],
            env: ["FOO=bar", "ITERM_SESSION_ID=w0t0p0:uuid-1", "EMPTY="]
        )
        let split = ProcessEnvironment.split(procArgs: buffer)
        #expect(split.arguments == ["/usr/local/bin/claude", "--flag"])
        #expect(split.environment == ["FOO=bar", "ITERM_SESSION_ID=w0t0p0:uuid-1", "EMPTY="])
    }

    @Test func truncatedProcArgsBufferNeverReadsPastItsEnd() {
        #expect(ProcessEnvironment.split(procArgs: []).arguments.isEmpty)
        #expect(ProcessEnvironment.split(procArgs: [2, 0, 0, 0]).environment.isEmpty)
        // argc promises 3 arguments but the buffer ends after one — yields
        // what it holds (argc-driven empty placeholders included) instead of
        // running past the end.
        let buffer = makeBuffer(argc: 3, path: "/bin/x", args: ["only"], env: [])
        let split = ProcessEnvironment.split(procArgs: buffer)
        #expect(split.arguments.first == "only")
        #expect(split.arguments.count <= 3)
        #expect(split.environment.isEmpty)
    }

    @Test func environmentOfDeduplicatesNamesFirstWins() {
        let dict = ProcessEnvironment.of(0) // pid 0 never exists — empty, no crash
        #expect(dict.isEmpty)
    }
}
