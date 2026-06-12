@testable import NemoNotch
import Testing

@Suite("CompletionDetector")
struct CompletionDetectorTests {
    private func c(_ key: String, _ name: String, _ active: Bool) -> CompletionCandidate {
        CompletionCandidate(key: key, name: name, isActive: active)
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
        #expect(result == ["Proj"])
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
        #expect(Set(result) == ["A", "B"])
    }

    @Test("a removed session is not a completion")
    func removedSessionNoCompletion() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "A", true)])
        let result = d.step([]) // session disappeared
        #expect(result.isEmpty)
    }

    @Test("merge dedups preserving order")
    func mergeDedups() {
        let merged = CompletionFlashNames.merge(existing: ["A", "B"], new: ["B", "C"])
        #expect(merged == ["A", "B", "C"])
    }
}
