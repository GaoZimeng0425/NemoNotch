@testable import NemoNotch
import Testing

@Suite("HotkeyDismissState")
struct HotkeyDismissStateTests {
    @Test("Mouse-hover open marks entered immediately so first mouse-leave closes")
    func mouseHoverOpen() {
        var state = HotkeyDismissState()
        state.didOpen(viaHotkey: false)

        #expect(state.mouseHasEnteredContent == true)
        #expect(state.observe(mouseInside: false) == .shouldClose)
    }

    @Test("Hotkey open keeps mouseHasEnteredContent false until mouse enters")
    func hotkeyOpenStartsUnentered() {
        var state = HotkeyDismissState()
        state.didOpen(viaHotkey: true)

        #expect(state.mouseHasEnteredContent == false)
        #expect(state.observe(mouseInside: false) == .ignore)
    }

    @Test("First mouse-inside event flips flag to entered and reports markedEntered")
    func mouseEnterMarksEntered() {
        var state = HotkeyDismissState()
        state.didOpen(viaHotkey: true)

        #expect(state.observe(mouseInside: true) == .markedEntered)
        #expect(state.mouseHasEnteredContent == true)
    }

    @Test("After entering, subsequent inside events are ignored")
    func subsequentInsideIgnored() {
        var state = HotkeyDismissState()
        state.didOpen(viaHotkey: true)
        _ = state.observe(mouseInside: true)

        #expect(state.observe(mouseInside: true) == .ignore)
    }

    @Test("After entering, going outside reports shouldClose")
    func leavingAfterEnterCloses() {
        var state = HotkeyDismissState()
        state.didOpen(viaHotkey: true)
        _ = state.observe(mouseInside: true)

        #expect(state.observe(mouseInside: false) == .shouldClose)
    }

    @Test("reset clears both flags")
    func resetClears() {
        var state = HotkeyDismissState()
        state.didOpen(viaHotkey: true)
        _ = state.observe(mouseInside: true)
        state.reset()

        #expect(state.openedViaHotkey == false)
        #expect(state.mouseHasEnteredContent == false)
    }
}
