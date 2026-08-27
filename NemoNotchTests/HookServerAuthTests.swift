import Foundation
@testable import NemoNotch
import Testing

// MARK: - M01:hook 服务器共享令牌的头解析

struct HookServerAuthTests {
    @Test func headerTokenExtractsValue() {
        let req = "POST /hook HTTP/1.1\r\nContent-Type: application/json\r\n"
            + "X-NemoNotch-Token: abc123\r\nContent-Length: 2\r\n\r\n{}"
        #expect(HookServer.headerToken(req) == "abc123")
    }

    @Test func headerNameIsCaseInsensitive() {
        let req = "POST /hook HTTP/1.1\r\nx-nemonotch-token: abc\r\n\r\n"
        #expect(HookServer.headerToken(req) == "abc")
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        let req = "POST /hook HTTP/1.1\r\nX-NemoNotch-Token:   spaced  \r\n\r\n"
        #expect(HookServer.headerToken(req) == "spaced")
    }

    @Test func colonAndEqualsInValueArePreserved() {
        let req = "POST /hook HTTP/1.1\r\nX-NemoNotch-Token: hex==:value\r\n\r\n"
        #expect(HookServer.headerToken(req) == "hex==:value")
    }

    @Test func missingOrEmptyTokenReturnsNil() {
        #expect(HookServer.headerToken("POST /hook HTTP/1.1\r\nContent-Length: 0\r\n\r\n") == nil)
        #expect(HookServer.headerToken("POST /hook HTTP/1.1\r\nX-NemoNotch-Token: \r\n\r\n") == nil)
        #expect(HookServer.headerToken("") == nil)
    }
}
