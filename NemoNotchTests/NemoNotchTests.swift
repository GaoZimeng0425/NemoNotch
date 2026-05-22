import Foundation
@testable import NemoNotch
import Testing

@Suite("NemoNotch smoke")
struct NemoNotchSmokeTests {
    @Test("Bundle identifier resolves")
    func bundleIdentifier() {
        let bundle = Bundle(for: HookServer.self)
        #expect(bundle.bundleIdentifier?.contains("NemoNotch") == true)
    }
}
