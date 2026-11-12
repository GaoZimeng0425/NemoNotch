import Foundation
@testable import NemoNotch
import Testing

@Suite("HerdrJumper")
struct HerdrJumperTests {
    @Test("CLI arguments: fixed verb, address as its own argument")
    func argumentsShape() {
        #expect(HerdrJumper.arguments(terminal: "vps/t7") == ["do", "agent.focus", "--terminal", "vps/t7"])
    }

    @Test("executable is the app binary under Contents/MacOS")
    func executableUnderMacOS() {
        let url = HerdrJumper.executableURL(appURL: URL(fileURLWithPath: "/Applications/Herdr.app"))
        #expect(url.path == "/Applications/Herdr.app/Contents/MacOS/Herdr")
    }

    @Test("exit 0 means focused")
    func planFocusedOnZero() {
        #expect(HerdrJumper.plan(exitStatus: 0) == .focused)
    }

    @Test("non-zero exit or no exit status falls back to opening Herdr")
    func planFallsBackWhenExitNonZero() {
        #expect(HerdrJumper.plan(exitStatus: 1) == .fallbackOpenApp)
        #expect(HerdrJumper.plan(exitStatus: nil) == .fallbackOpenApp)
    }
}
