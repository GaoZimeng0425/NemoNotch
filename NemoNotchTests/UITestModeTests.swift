@testable import NemoNotch
import Testing

@Suite("UITestMode")
struct UITestModeTests {
    @Test("无 --uitest 时 isActive 为 false")
    func inactive() {
        #expect(UITestMode.isActive(in: ["NemoNotch"]) == false)
    }

    @Test("有 --uitest 时 isActive 为 true")
    func active() {
        #expect(UITestMode.isActive(in: ["NemoNotch", "--uitest"]) == true)
    }

    @Test("缺省 tab 为 .overview")
    func defaultTab() {
        #expect(UITestMode.tab(in: ["--uitest"]) == .overview)
    }

    @Test("--tab=claude 解析为 .claude")
    func parsedTab() {
        #expect(UITestMode.tab(in: ["--uitest", "--tab=claude"]) == .claude)
    }

    @Test("非法 tab 回落 .overview")
    func invalidTab() {
        #expect(UITestMode.tab(in: ["--tab=nope"]) == .overview)
    }
}
