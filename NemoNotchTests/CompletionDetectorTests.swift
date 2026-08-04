@testable import NemoNotch
import Foundation
import Testing

@Suite("CompletionDetector")
struct CompletionDetectorTests {
    private func c(_ key: String, _ name: String, _ active: Bool) -> CompletionCandidate {
        CompletionCandidate(key: key, name: name, isActive: active, source: .ai(.claude))
    }

    private func item(_ name: String, _ source: CompletionSource = .ai(.claude)) -> CompletionItem {
        CompletionItem(name: name, source: source)
    }

    @Test("first sample never reports completions")
    func firstSampleNoCompletion() {
        var d = CompletionDetector()
        let result = d.step([c("ai:1", "Proj", false), c("ai:2", "Other", true)])
        #expect(result.isEmpty)
    }

    @Test("active then idle reports the name once")
    func activeToIdleCompletes() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "Proj", true)])
        let result = d.step([c("ai:1", "Proj", false)])
        #expect(result.map(\.name) == ["Proj"])
    }

    @Test("completed item carries its source")
    func completedCarriesSource() {
        var d = CompletionDetector()
        _ = d.step([CompletionCandidate(key: "ai:1", name: "Proj", isActive: true, source: .ai(.gemini))])
        let result = d.step([CompletionCandidate(key: "ai:1", name: "Proj", isActive: false, source: .ai(.gemini))])
        #expect(result == [item("Proj", .ai(.gemini))])
    }

    @Test("idle staying idle does not report")
    func idleStaysIdle() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "Proj", false)])
        let result = d.step([c("ai:1", "Proj", false)])
        #expect(result.isEmpty)
    }

    @Test("working staying working does not report")
    func workingStaysWorking() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "Proj", true)])
        let result = d.step([c("ai:1", "Proj", true)])
        #expect(result.isEmpty)
    }

    @Test("idle then working (new turn) does not report")
    func idleToWorking() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "Proj", false)])
        let result = d.step([c("ai:1", "Proj", true)])
        #expect(result.isEmpty)
    }

    @Test("multiple simultaneous completions all reported")
    func multipleCompletions() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "A", true), c("agent:x", "B", true)])
        let result = d.step([c("ai:1", "A", false), c("agent:x", "B", false)])
        #expect(Set(result.map(\.name)) == ["A", "B"])
    }

    @Test("a removed session is not a completion")
    func removedSessionNoCompletion() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "A", true)])
        let result = d.step([]) // session disappeared
        #expect(result.isEmpty)
    }

    @Test("merge dedups by name preserving order")
    func mergeDedups() {
        let merged = CompletionFlashNames.merge(
            existing: [item("A"), item("B")],
            new: [item("B"), item("C")]
        )
        #expect(merged.map(\.name) == ["A", "B", "C"])
    }

    // MARK: - Rich-field pass-through

    private func rich(
        _ key: String,
        _ name: String,
        _ active: Bool,
        subtitle: String? = nil,
        tool: String? = nil,
        model: String? = nil,
        tokenDisplay: String? = nil,
        duration: TimeInterval? = nil
    ) -> CompletionCandidate {
        CompletionCandidate(
            key: key, name: name, isActive: active, source: .ai(.claude),
            subtitle: subtitle, tool: tool, model: model,
            tokenDisplay: tokenDisplay, duration: duration
        )
    }

    @Test("completion item carries rich fields from the candidate")
    func richFieldsCarriedThrough() {
        var d = CompletionDetector()
        _ = d.step([rich("ai:1", "NemoNotch", true,
                          subtitle: "fix auth bug", tool: "Edit",
                          model: "Sonnet 4.5", tokenDisplay: "12.4k", duration: 134)])
        let result = d.step([rich("ai:1", "NemoNotch", false,
                                  subtitle: "fix auth bug", tool: "Edit",
                                  model: "Sonnet 4.5", tokenDisplay: "12.4k", duration: 134)])
        #expect(result.count == 1)
        let item = result[0]
        #expect(item.subtitle == "fix auth bug")
        #expect(item.tool == "Edit")
        #expect(item.model == "Sonnet 4.5")
        #expect(item.tokenDisplay == "12.4k")
        #expect(item.duration == 134)
    }

    @Test("rich fields default to nil when not supplied")
    func richFieldsDefaultNil() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "Proj", true)])
        let result = d.step([c("ai:1", "Proj", false)])
        #expect(result.count == 1)
        #expect(result[0].subtitle == nil)
        #expect(result[0].tool == nil)
        #expect(result[0].model == nil)
        #expect(result[0].tokenDisplay == nil)
        #expect(result[0].duration == nil)
    }

    @Test("merge overwrites same-name item fields with newer non-nil values")
    func mergeOverwritesFields() {
        var existing = item("A")
        existing.subtitle = "old subtitle"
        var incoming = item("A")
        incoming.subtitle = "new subtitle"
        incoming.tool = "Edit"
        let merged = CompletionFlashNames.merge(existing: [existing], new: [incoming])
        #expect(merged.count == 1)
        #expect(merged[0].subtitle == "new subtitle")
        #expect(merged[0].tool == "Edit")
    }

    @Test("merge keeps existing field when newer is nil")
    func mergeKeepsExistingOnNil() {
        var existing = item("A")
        existing.subtitle = "kept"
        var incoming = item("A")  // subtitle nil
        incoming.tool = "Edit"
        let merged = CompletionFlashNames.merge(existing: [existing], new: [incoming])
        #expect(merged[0].subtitle == "kept")
        #expect(merged[0].tool == "Edit")
    }
}
