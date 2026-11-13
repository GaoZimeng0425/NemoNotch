import Foundation
@testable import NemoNotch
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

    @Test("completed item carries its source and kind")
    func completedCarriesSource() {
        var d = CompletionDetector()
        _ = d.step([CompletionCandidate(key: "ai:1", name: "Proj", isActive: true, source: .ai(.gemini))])
        let result = d.step([CompletionCandidate(key: "ai:1", name: "Proj", isActive: false, source: .ai(.gemini))])
        var expected = item("Proj", .ai(.gemini))
        expected.key = "ai:1"
        expected.kind = .turnDone
        #expect(result == [expected])
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

    @Test("a session vanishing mid-work reports sessionLost; one already idle stays silent")
    func disappearanceDependsOnPriorActivity() {
        var d = CompletionDetector()
        var busy = c("ai:1", "A", true)
        busy.jump = CompletionJump(hostPID: 42, hostBundleId: nil, tabLink: nil)
        _ = d.step([busy])
        // No Stop ever came and the unit is gone: the work was not finished.
        let lost = d.step([])
        #expect(lost.count == 1)
        #expect(lost[0].kind == .sessionLost)
        #expect(lost[0].name == "A")
        #expect(lost[0].key == "ai:1")
        #expect(lost[0].jump?.hostPID == 42)
        // An already-idle unit vanishing is not news.
        _ = d.step([c("ai:2", "B", false)])
        #expect(d.step([]).isEmpty)
    }

    // MARK: - Reminder kinds

    @Test("completion kind defaults to turnDone and follows completesAs")
    func completionKindFollowsCandidate() {
        var d = CompletionDetector()
        _ = d.step([c("ai:1", "Proj", true)])
        #expect(d.step([c("ai:1", "Proj", false)]).map(\.kind) == [.turnDone])

        var idle = c("ai:2", "Other", false)
        idle.completesAs = .sessionLost
        _ = d.step([c("ai:2", "Other", true)])
        #expect(d.step([idle]).map(\.kind) == [.sessionLost])
    }

    @Test("an agent that sat in error reports agentError, not a green done")
    func agentErrorEdge() {
        var d = CompletionDetector()
        var err = c("agent:x", "Hermes", true)
        err.wasError = true
        _ = d.step([err])
        #expect(d.step([c("agent:x", "Hermes", false)]).map(\.kind) == [.agentError])
    }

    @Test("sessionKey parses only the three session-scoped key prefixes")
    func sessionKeyParsing() {
        var i = item("A")
        i.key = "ai:s1"
        #expect(i.sessionKey == "s1")
        i.key = "ask:s1"
        #expect(i.sessionKey == "s1")
        i.key = "fail:s1"
        #expect(i.sessionKey == "s1")
        i.key = "agent:x"
        #expect(i.sessionKey == nil)
        i.key = nil
        #expect(i.sessionKey == nil)
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
        _ = d.step([rich(
            "ai:1",
            "NemoNotch",
            true,
            subtitle: "fix auth bug",
            tool: "Edit",
            model: "Sonnet 4.5",
            tokenDisplay: "12.4k",
            duration: 134
        )])
        let result = d.step([rich(
            "ai:1",
            "NemoNotch",
            false,
            subtitle: "fix auth bug",
            tool: "Edit",
            model: "Sonnet 4.5",
            tokenDisplay: "12.4k",
            duration: 134
        )])
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
        var incoming = item("A") // subtitle nil
        incoming.tool = "Edit"
        let merged = CompletionFlashNames.merge(existing: [existing], new: [incoming])
        #expect(merged[0].subtitle == "kept")
        #expect(merged[0].tool == "Edit")
    }

    @Test("external payload is replaced whole-card on merge: a missing body or jump clears the old one")
    func mergeReplacesExternalPayloadWholeCard() {
        var existing = item("Demo", .external(icon: nil))
        existing.key = "ext:Demo::dl-1"
        existing.external = ExternalCardContent(app: "Demo", title: "下载完成", body: "A", jumpBundleId: "com.old.app")
        existing.jump = CompletionJump(hostPID: nil, hostBundleId: "com.old.app", tabLink: nil)
        var incoming = item("Demo", .external(icon: nil))
        incoming.key = "ext:Demo::dl-1"
        incoming.external = ExternalCardContent(app: "Demo", title: "下载完成", body: nil, jumpBundleId: nil)
        let merged = CompletionFlashNames.merge(existing: [existing], new: [incoming])
        #expect(merged.count == 1)
        #expect(merged[0].external?.body == nil)
        #expect(merged[0].external?.jumpBundleId == nil)
        #expect(merged[0].jump == nil)
    }

    @Test("external item uses its provided card key as toastKey")
    func externalItemToastKeyUsesProvidedKey() {
        var item = item("Demo", .external(icon: nil))
        item.key = "ext:App::k1"
        #expect(item.toastKey == "ext:App::k1")
    }

    @Test("forget drops units so a disabled source's removal is silent, not sessionLost")
    func forgetPreventsSessionLost() {
        // Prime: an active unit the detector remembers.
        var d = CompletionDetector()
        _ = d.step([c("ai:t1", "Proj", true)])

        // Toggle-off path: forget BEFORE the unit leaves the snapshot.
        d.forget(["ai:t1"])
        let afterForget = d.step([])
        #expect(afterForget.isEmpty)

        // Control: without forget, the same vanishing reports sessionLost —
        // proving the guard has teeth (mutate `d.forget` away to see red).
        var control = CompletionDetector()
        _ = control.step([c("ai:t2", "Proj", true)])
        let vanished = control.step([])
        #expect(vanished.count == 1)
        #expect(vanished[0].kind == .sessionLost)
    }

    @Test("forget is narrow: other units still report normally")
    func forgetIsNarrow() {
        var d = CompletionDetector()
        _ = d.step([c("ai:keep", "Keep", true), c("ai:drop", "Drop", true)])

        d.forget(["ai:drop"])
        let result = d.step([c("ai:keep", "Keep", false)])
        #expect(result.count == 1)
        #expect(result[0].key == "ai:keep")
        #expect(result[0].kind == .turnDone)
    }
}

@Suite("AttentionDetector")
struct AttentionDetectorTests {
    @Test("arrival fires once per wait; a context change does not replay it")
    func arrivalIdempotent() {
        var d = AttentionDetector()
        let first = d.step([(key: "ai:1", attention: ReminderKind?.some(.needsApproval))])
        #expect(first.arrived.count == 1)
        #expect(first.arrived[0].key == "ai:1")
        #expect(first.arrived[0].kind == .needsApproval)
        // Same wait, different tool shape — the arrival gesture must not replay.
        let again = d.step([(key: "ai:1", attention: .needsDecision)])
        #expect(again.arrived.isEmpty)
        #expect(again.retracted.isEmpty)
    }

    @Test("leaving the wait retracts; vanishing retracts too")
    func retraction() {
        var d = AttentionDetector()
        _ = d.step([(key: "ai:1", attention: .needsApproval)])
        let left = d.step([(key: "ai:1", attention: nil)])
        #expect(left.retracted == ["ai:1"])

        _ = d.step([(key: "ai:2", attention: .needsDecision)])
        let gone = d.step([])
        #expect(gone.retracted == ["ai:2"])
    }

    @Test("a session never in the wait never retracts")
    func noFalseRetraction() {
        var d = AttentionDetector()
        let idle = d.step([(key: "ai:1", attention: nil)])
        #expect(idle.arrived.isEmpty)
        #expect(idle.retracted.isEmpty)
    }
}
