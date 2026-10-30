@testable import NemoNotch
import Network
import Testing

@Suite("HookServerBind")
struct HookServerBindTests {
    @Test("the hook listener is pinned to IPv4 loopback, not every interface")
    func pinnedToLoopback() {
        let params = HookServer.listenerParameters(port: 45831)
        #expect(params.requiredLocalEndpoint == .hostPort(host: .ipv4(.loopback), port: 45831))
    }
}
