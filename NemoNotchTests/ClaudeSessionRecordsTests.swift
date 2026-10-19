import Foundation
@testable import NemoNotch
import Testing

@Suite("ClaudeSessionRecords")
struct ClaudeSessionRecordsTests {
    private func record(_ fields: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
    }

    @Test func parsesTheFieldsItNeeds() {
        let r = ClaudeSessionRecords.parse(record([
            "pid": 71121, "sessionId": "7e3d", "cwd": "/w/Vela", "name": "vela-6c", "status": "busy",
            "peerProtocol": 1,
        ]))
        #expect(r == .init(pid: 71121, sessionId: "7e3d", cwd: "/w/Vela", name: "vela-6c", busy: true))
        #expect(ClaudeSessionRecords.parse(record(["pid": 5, "sessionId": "s", "status": "idle"]))?.busy == false)
        #expect(ClaudeSessionRecords.parse(record(["pid": 5, "sessionId": "s", "status": "shell"]))?.busy == nil)
    }

    @Test func recordsWithoutEssentialsAreSkipped() {
        #expect(ClaudeSessionRecords.parse(record(["sessionId": "s"])) == nil)
        #expect(ClaudeSessionRecords.parse(record(["pid": 1, "sessionId": "s"])) == nil)
        #expect(ClaudeSessionRecords.parse(record(["pid": 9, "sessionId": ""])) == nil)
        #expect(ClaudeSessionRecords.parse(Data("not json".utf8)) == nil)
    }

    @Test func scanKeepsOnlyLiveProcessesAndJSONFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try record(["pid": 100, "sessionId": "live"]).write(to: URL(fileURLWithPath: "\(dir)/100.json"))
        try record(["pid": 200, "sessionId": "dead"]).write(to: URL(fileURLWithPath: "\(dir)/200.json"))
        try Data("x".utf8).write(to: URL(fileURLWithPath: "\(dir)/100.abc.key"))
        let live = ClaudeSessionRecords.scanLive(directory: dir, isAlive: { $0 == 100 })
        #expect(live.map(\.sessionId) == ["live"])
    }

    @Test func thisProcessIsAlive() {
        #expect(ClaudeSessionRecords.isAlive(getpid()))
        #expect(!ClaudeSessionRecords.isAlive(1_234_567))
    }

    // MARK: Merge rule

    @Test func newSessionStartsFromTheRecordStatus() {
        #expect(ClaudeRecordMerge.phase(current: nil, busy: true, silentFor: .infinity) == .processing)
        #expect(ClaudeRecordMerge.phase(current: nil, busy: false, silentFor: .infinity) == .idle)
        #expect(ClaudeRecordMerge.phase(current: nil, busy: nil, silentFor: .infinity) == .idle)
    }

    @Test func hooksWinUnlessThePhaseCannotBeTrue() {
        // A turn the hooks didn't see begin.
        #expect(ClaudeRecordMerge.phase(current: .idle, busy: true, silentFor: 0) == .processing)
        // A Stop that never came — only after the grace.
        #expect(ClaudeRecordMerge.phase(current: .processing, busy: false, silentFor: 3) == nil)
        #expect(ClaudeRecordMerge.phase(current: .processing, busy: false, silentFor: 30) == .idle)
        // Compatible states are left alone.
        #expect(ClaudeRecordMerge.phase(current: .waitingForInput, busy: false, silentFor: 999) == nil)
        #expect(ClaudeRecordMerge.phase(current: .processing, busy: true, silentFor: 999) == nil)
    }
}

@MainActor
@Suite("ClaudeProvider records")
struct ClaudeProviderRecordsTests {
    private func rec(_ id: String, pid: Int32 = 4242, busy: Bool? = false) -> ClaudeSessionRecords.Record {
        .init(pid: pid, sessionId: id, cwd: "/tmp/nemo-records-\(id)", name: "name-\(id)", busy: busy)
    }

    @Test func recordsAddSessionsAndAGoneProcessRemovesThem() {
        let store = AISessionStore()
        let provider = ClaudeProvider(store: store)
        provider.applyRecords([rec("a"), rec("b", busy: true)])
        #expect(store.get("a")?.phase == .idle)
        #expect(store.get("a")?.recordName == "name-a")
        #expect(store.get("b")?.phase == .processing)

        provider.applyRecords([rec("b", busy: true)])
        #expect(store.get("a") == nil)
        #expect(store.get("b") != nil)
    }

    @Test func aHookOnlySessionIsNotRemovedByRecords() {
        let store = AISessionStore()
        let provider = ClaudeProvider(store: store)
        provider.handleEvent(HookEvent(hookEventName: "UserPromptSubmit", sessionId: "hook-only"))
        provider.applyRecords([])
        #expect(store.get("hook-only") != nil)
    }

    @Test func aSessionEndedByItsHookIsNotBroughtBack() {
        let store = AISessionStore()
        let provider = ClaudeProvider(store: store)
        provider.applyRecords([rec("a")])
        provider.handleEvent(HookEvent(hookEventName: "SessionEnd", sessionId: "a"))
        provider.applyRecords([rec("a")])
        #expect(store.get("a") == nil)
    }
}
