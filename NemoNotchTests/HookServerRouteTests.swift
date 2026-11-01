@testable import NemoNotch
import Testing

@Suite("HookServer /v1/toast route")
struct HookServerRouteTests {
    @Test func toastResponseStatusMapping() {
        #expect(HookServer.toastResponseStatus(.ok) == "200 OK")
        #expect(HookServer.toastResponseStatus(.rejected(.malformedJSON)) == "400 Bad Request")
    }
}
