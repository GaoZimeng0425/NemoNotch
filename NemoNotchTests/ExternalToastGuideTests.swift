@testable import NemoNotch
import Testing

/// 指南常量锚点断言:常量是 docs/external-toast-agent-guide.md 在设置里的投影,
/// 此测试防它被误清空、或契约字段名整体消失(锚点子串全数删尽才红——单处
/// 损坏在多处出现的锚上测不到,变异验证请选唯一出现的锚,如 jumpURL)。
struct ExternalToastGuideTests {
    @Test func guideCoversEndpointAndCredentials() {
        let text = ExternalToastGuide.text
        #expect(!text.isEmpty)
        #expect(text.contains("/v1/toast"))
        #expect(text.contains("hook-port"))
        #expect(text.contains("hook-token"))
        #expect(text.contains("X-NemoNotch-Token"))
    }

    @Test func guideCoversContractFieldsAndAcceptance() {
        let text = ExternalToastGuide.text
        #expect(text.contains("jumpBundleId"))
        #expect(text.contains("jumpURL"))
        #expect(text.contains("验收清单"))
    }
}
