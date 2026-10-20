import Foundation
@testable import NemoNotch
import Testing

// .serialized: these tests share the process-wide `overlay` via
// `setOverlayForTests`, so they must not run concurrently.
@Suite("ModelContextWindow", .serialized)
struct ModelContextWindowTests {
    @Test("Curated exact match wins and is never overridden")
    func curatedExactMatch() {
        // glm-5.2 is curated to 1_048_576.
        #expect(ModelContextWindow.limit(for: "glm-5.2") == 1_048_576)

        // Even if the overlay claims a different value, the curated entry wins.
        ModelContextWindow.setOverlayForTests(["glm-5.2": 999_999])
        #expect(ModelContextWindow.limit(for: "glm-5.2") == 1_048_576)
        ModelContextWindow.setOverlayForTests([:])
    }

    @Test("Claude ids resolve to Claude Code's window per family-version")
    func claudeTable() {
        #expect(ModelContextWindow.limit(for: "claude-opus-5-5") == 1_000_000)
        #expect(ModelContextWindow.limit(for: "claude-opus-4-8-20250805") == 1_000_000)
        #expect(ModelContextWindow.limit(for: "claude-opus-4-5-20251101") == 200_000)
        #expect(ModelContextWindow.limit(for: "claude-opus-4-20250514") == 200_000)
        #expect(ModelContextWindow.limit(for: "claude-sonnet-4-5-20250929") == 200_000)
        #expect(ModelContextWindow.limit(for: "claude-sonnet-4-6") == 1_000_000)
        #expect(ModelContextWindow.limit(for: "claude-haiku-4-5-20251001") == 200_000)
        // Dot-versioned and vendor-prefixed forms (opencode / OpenRouter ids).
        #expect(ModelContextWindow.limit(for: "anthropic/claude-opus-4.8") == 1_000_000)
        // Claude Code's own 1M alias.
        #expect(ModelContextWindow.limit(for: "claude-sonnet-4-5[1m]") == 1_000_000)
        // An unlisted Claude id is 200K until seen holding more.
        #expect(ModelContextWindow.limit(for: "claude-newfamily-9") == 200_000)
    }

    @Test("The Claude table runs before the overlay")
    func claudeBeatsOverlay() {
        ModelContextWindow.setOverlayForTests(["claude-sonnet-4-5-20250929": 1_000_000])
        #expect(ModelContextWindow.limit(for: "claude-sonnet-4-5-20250929") == 200_000)
        ModelContextWindow.setOverlayForTests([:])
    }

    @Test("A Claude session seen past its listed window ran with 1M")
    func observedUpgrade() {
        #expect(ModelContextWindow.limit(for: "claude-sonnet-4-5", observed: 150_000) == 200_000)
        #expect(ModelContextWindow.limit(for: "claude-sonnet-4-5", observed: 230_000) == 1_000_000)
        #expect(ModelContextWindow.limit(for: "claude-newfamily-9", observed: 400_000) == 1_000_000)
        // Never for a non-Claude model: its listed window stands.
        #expect(ModelContextWindow.limit(for: "glm-5.1", observed: 300_000) == 200_000)
    }

    @Test("Unknown model falls back to default")
    func defaultFallback() {
        #expect(ModelContextWindow.limit(for: "totally-unknown-model-xyz") == ModelContextWindow.defaultValue)
    }

    @Test("Overlay fills gaps for models not in the curated table")
    func overlayFillsGap() {
        ModelContextWindow.setOverlayForTests(["glm-9": 5_000_000])
        #expect(ModelContextWindow.limit(for: "glm-9") == 5_000_000)
        // Vendor-prefixed form normalizes to the same key.
        #expect(ModelContextWindow.limit(for: "z-ai/glm-9") == 5_000_000)
        ModelContextWindow.setOverlayForTests([:])
    }

    @Test("normalize strips OpenRouter vendor prefix and lowercases")
    func normalize() {
        #expect(ModelContextWindow.normalize("z-ai/glm-5.2") == "glm-5.2")
        #expect(ModelContextWindow.normalize("anthropic/claude-opus-4.8") == "claude-opus-4.8")
        #expect(ModelContextWindow.normalize("google/gemini-3.5-flash") == "gemini-3.5-flash")
        #expect(ModelContextWindow.normalize("GLM-5.2") == "glm-5.2")
        #expect(ModelContextWindow.normalize("bare-id") == "bare-id")
    }

    @Test("parse extracts context_length keyed by normalized id")
    func parseCatalog() throws {
        // Minimal OpenRouter /api/v1/models-shaped payload.
        let payload = try #require("""
        {
          "data": [
            { "id": "z-ai/glm-5.2", "context_length": 1048576 },
            { "id": "anthropic/claude-opus-4.8", "context_length": 1000000 },
            { "id": "google/gemini-3.5-flash", "context_length": 1048576 },
            { "id": "noctx/model", "context_length": 0 },
            { "id": "missing-field/model" }
          ]
        }
        """.data(using: .utf8))

        let parsed = ModelContextWindow.parse(data: payload)

        #expect(parsed["glm-5.2"] == 1_048_576)
        #expect(parsed["claude-opus-4.8"] == 1_000_000)
        #expect(parsed["gemini-3.5-flash"] == 1_048_576)
        // Zero / missing context_length are dropped.
        #expect(parsed["noctx/model"] == nil)
        #expect(parsed["missing-field/model"] == nil)
        #expect(parsed.count == 3)
    }

    @Test("parse tolerates malformed input")
    func parseMalformed() {
        #expect(ModelContextWindow.parse(data: Data("not json".utf8)).isEmpty)
        #expect(ModelContextWindow.parse(data: Data("{}".utf8)).isEmpty)
    }
}
