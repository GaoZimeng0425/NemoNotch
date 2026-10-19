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
        #expect(r?.pid == 71121)
        #expect(r?.sessionId == "7e3d")
        #expect(r?.cwd == "/w/Vela")
        #expect(r?.name == "vela-6c")
        #expect(r?.busy == true)
        let stamped = ClaudeSessionRecords.parse(record([
            "pid": 5, "sessionId": "s", "statusUpdatedAt": 1_792_390_454_128, "startedAt": 1_792_381_813_396,
        ]))
        #expect(stamped?.statusUpdatedAt == Date(timeIntervalSince1970: 1_792_390_454.128))
        #expect(stamped?.startedAt == Date(timeIntervalSince1970: 1_792_381_813.396))
        #expect(ClaudeSessionRecords.parse(record(["pid": 5, "sessionId": "s", "status": "idle"]))?.busy == false)
        #expect(ClaudeSessionRecords.parse(record(["pid": 5, "sessionId": "s", "status": "shell"]))?.busy == nil)
    }

    @Test func nonInteractiveRecordsAreSkipped() {
        #expect(ClaudeSessionRecords.parse(record(["pid": 5, "sessionId": "s", "kind": "print"])) == nil)
        #expect(ClaudeSessionRecords.parse(record(["pid": 5, "sessionId": "s", "kind": "interactive"])) != nil)
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
        let live = ClaudeSessionRecords.scanLive(directory: dir, isAlive: { $0.pid == 100 })
        #expect(live?.map(\.sessionId) == ["live"])
        #expect(ClaudeSessionRecords.scanLive(directory: "\(dir)/missing") == nil)
    }

    @Test func thisProcessIsAliveUnlessThePidWasReused() {
        #expect(ClaudeSessionRecords.isAlive(getpid()))
        #expect(!ClaudeSessionRecords.isAlive(1_234_567))
        // A record written long before this process started: pid reuse.
        #expect(!ClaudeSessionRecords.isAlive(getpid(), startedAt: Date(timeIntervalSince1970: 0)))
        #expect(ClaudeSessionRecords.isAlive(getpid(), startedAt: Date()))
    }

    @Test func tailOffsetStartsOnAWholeLine() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc\n".write(toFile: path, atomically: true, encoding: .utf8)
        // 15 bytes back lands mid "bbbb…": move to the start of "cccc…" (22).
        #expect(ConversationParser.lineAlignedOffset(filePath: path, tailBytes: 15) == 22)
        #expect(ConversationParser.lineAlignedOffset(filePath: path, tailBytes: 1000) == 0)
    }

    // MARK: Merge rule

    @Test func newSessionStartsFromTheRecordStatus() {
        #expect(ClaudeRecordMerge.phase(current: nil, busy: true, recordIsNewer: false) == .processing)
        #expect(ClaudeRecordMerge.phase(current: nil, busy: false, recordIsNewer: false) == .idle)
        #expect(ClaudeRecordMerge.phase(current: nil, busy: nil, recordIsNewer: false) == .idle)
    }

    @Test func aStaleRecordNeverOverridesTheHooks() {
        // Esc just set idle; the record still says busy from before.
        #expect(ClaudeRecordMerge.phase(current: .idle, busy: true, recordIsNewer: false) == nil)
        #expect(ClaudeRecordMerge.phase(current: .processing, busy: false, recordIsNewer: false) == nil)
    }

    @Test func aNewerRecordCorrectsAnImpossiblePhase() {
        #expect(ClaudeRecordMerge.phase(current: .idle, busy: true, recordIsNewer: true) == .processing)
        #expect(ClaudeRecordMerge.phase(current: .processing, busy: false, recordIsNewer: true) == .idle)
        let approval = SessionPhase.waitingForApproval(.init(
            toolUseId: "t",
            toolName: "Bash",
            toolInput: nil,
            receivedAt: Date()
        ))
        #expect(ClaudeRecordMerge.phase(current: approval, busy: false, recordIsNewer: true) == .idle)
        // Compatible states are left alone.
        #expect(ClaudeRecordMerge.phase(current: .waitingForInput, busy: false, recordIsNewer: true) == nil)
        #expect(ClaudeRecordMerge.phase(current: .processing, busy: true, recordIsNewer: true) == nil)
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
        provider.applyRecords([rec("a"), rec("b", busy: true)], isAlive: { _ in true })
        #expect(store.get("a")?.phase == .idle)
        #expect(store.get("a")?.recordName == "name-a")
        #expect(store.get("b")?.phase == .processing)

        // Missing from one scan while its process lives (a torn read): kept.
        provider.applyRecords([rec("b", pid: 1, busy: true)], isAlive: { _ in true })
        #expect(store.get("a") != nil)
        // Its process is gone: ended.
        provider.applyRecords([rec("b", pid: 1, busy: true)], isAlive: { _ in false })
        #expect(store.get("a") == nil)
        #expect(store.get("b") != nil)
    }

    @Test func aProcessWhoseRecordNamesAnotherSessionEndsTheOld() {
        let store = AISessionStore()
        let provider = ClaudeProvider(store: store)
        provider.applyRecords([rec("old", pid: 77)], isAlive: { _ in true })
        // `/clear`: same process, new session id.
        provider.applyRecords([rec("new", pid: 77)], isAlive: { _ in true })
        #expect(store.get("old") == nil)
        #expect(store.get("new") != nil)
    }

    @Test func aHookOnlySessionIsNotRemovedByRecords() {
        let store = AISessionStore()
        let provider = ClaudeProvider(store: store)
        provider.handleEvent(HookEvent(hookEventName: "UserPromptSubmit", sessionId: "hook-only"))
        provider.applyRecords([], isAlive: { _ in false })
        #expect(store.get("hook-only") != nil)
    }

    @Test func aSessionEndedByItsHookIsNotBroughtBack() {
        let store = AISessionStore()
        let provider = ClaudeProvider(store: store)
        provider.applyRecords([rec("a")], isAlive: { _ in true })
        provider.handleEvent(HookEvent(hookEventName: "SessionEnd", sessionId: "a"))
        provider.applyRecords([rec("a")], isAlive: { _ in true })
        #expect(store.get("a") == nil)
    }
}
