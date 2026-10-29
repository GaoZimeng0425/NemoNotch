import Foundation
@testable import NemoNotch
import Testing

@Suite("CompletionToastClick")
struct CompletionToastClickTests {
    private let deadline = Date(timeIntervalSinceReferenceDate: 0)
    private let target = CompletionJump(hostPID: 4242, hostBundleId: "com.googlecode.iterm2", tabLink: nil)

    private func toast(jump: CompletionJump?) -> CompletionToast {
        var item = CompletionItem(name: "NemoNotch", source: .ai(.claude))
        item.jump = jump
        return CompletionToast(id: UUID(), item: item, deadline: deadline)
    }

    @Test("clicking a session card jumps to its host app and names that card to close")
    func cardJumps() {
        let toasts = [toast(jump: nil), toast(jump: target)]
        #expect(CompletionToastClick.action(for: .card(1), toasts: toasts) == .jump(toasts[1].id, target))
    }

    @Test("clicking a card with nowhere to jump just closes it")
    func cardWithoutTargetDismisses() {
        let toasts = [toast(jump: nil)]
        #expect(CompletionToastClick.action(for: .card(0), toasts: toasts) == .dismiss(toasts[0].id))
    }

    @Test("the close button only closes, even on a jumpable card")
    func closeNeverJumps() {
        let toasts = [toast(jump: target)]
        #expect(CompletionToastClick.action(for: .close(0), toasts: toasts) == .dismiss(toasts[0].id))
    }

    @Test("misses and stale indexes do nothing")
    func missesDoNothing() {
        let toasts = [toast(jump: target)]
        #expect(CompletionToastClick.action(for: nil, toasts: toasts) == nil)
        #expect(CompletionToastClick.action(for: .card(3), toasts: toasts) == nil)
        #expect(CompletionToastClick.action(for: .close(3), toasts: toasts) == nil)
    }

    @Test("a jump target exists only when the session recorded something to jump to")
    func makeRequiresSomeField() {
        #expect(CompletionJump.make(hostPID: nil, hostBundleId: nil, tabLink: nil) == nil)
        #expect(CompletionJump.make(hostPID: nil, hostBundleId: "dev.zcode.app", tabLink: nil)?
            .hostBundleId == "dev.zcode.app")
        // A tab link alone is enough — the terminal reveals its own tab.
        #expect(CompletionJump.make(hostPID: nil, hostBundleId: nil, tabLink: "iterm2://tab/1")?
            .tabLink == "iterm2://tab/1")
    }

    @Test("the detector snapshots the jump target onto the completed item")
    func detectorCarriesJump() {
        var detector = CompletionDetector()
        func candidate(_ active: Bool) -> CompletionCandidate {
            CompletionCandidate(
                key: "ai:1", name: "NemoNotch", isActive: active, source: .ai(.claude),
                subtitle: nil, tool: nil, model: nil, tokenDisplay: nil, duration: nil,
                jump: target
            )
        }
        _ = detector.step([candidate(true)])
        #expect(detector.step([candidate(false)]).first?.jump == target)
    }

    @Test("a same-session refresh without a target keeps the older one")
    func mergeKeepsJump() {
        var older = CompletionItem(name: "NemoNotch", source: .ai(.claude))
        older.key = "ai:1"
        older.jump = target
        var newer = CompletionItem(name: "NemoNotch", source: .ai(.claude))
        newer.key = "ai:1"
        #expect(CompletionFlashNames.merge(existing: [older], new: [newer]).first?.jump == target)
    }
}
