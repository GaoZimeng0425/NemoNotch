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

    @Test("Claude family fallback covers dated/dot-versioned ids")
    func claudeFamilyFallback() {
        #expect(ModelContextWindow.limit(for: "claude-opus-4-8-20250805") == 1_048_576)
        #expect(ModelContextWindow.limit(for: "claude-sonnet-4-5-20250929") == 1_048_576)
        #expect(ModelContextWindow.limit(for: "OPUS-something") == 1_048_576)
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
    func parseCatalog() {
        // Minimal OpenRouter /api/v1/models-shaped payload.
        let payload = """
        {
          "data": [
            { "id": "z-ai/glm-5.2", "context_length": 1048576 },
            { "id": "anthropic/claude-opus-4.8", "context_length": 1000000 },
            { "id": "google/gemini-3.5-flash", "context_length": 1048576 },
            { "id": "noctx/model", "context_length": 0 },
            { "id": "missing-field/model" }
          ]
        }
        """.data(using: .utf8)!

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
