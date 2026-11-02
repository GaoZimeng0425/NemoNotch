import Foundation
@testable import NemoNotch
import Testing

/// Byte-level framing of a buffered HTTP request. `hasCompleteHTTPRequest`
/// is the receive loop's ONLY gate (HookServer.swift `receive`): it decides
/// whether the bytes read so far form a whole request or more must be read.
/// Every case feeds raw bytes and asserts the literal Bool. A gate that says
/// "complete" as soon as the header block lands (the original bug: Swift
/// clusters "\r\n" into one Character, so `firstIndex(of: "\r")` was always
/// nil and the Content-Length branch was dead code) passes only ③④ here and
/// fails ①②⑥⑦. ⑦ additionally guards against a one-line String fix
/// (`after.range(of: "\r\n")`): with Content-Length as the LAST header there
/// is no CRLF after it inside the header block, so that fix is still
/// always-true — and curl 8.7.1 (hook-sender.sh) always sends it last.
@Suite("HookServerFraming")
struct HookServerFramingTests {
    /// Fixed valid toast body; every Content-Length below is derived from
    /// `json.count`, never hand-counted.
    private static let json = Data(
        #"{"schema":1,"app":"probe","title":"framing probe","body":"two-segment probe"}"#.utf8
    )

    /// Assemble `request-line CRLF (header CRLF)* CRLF body` as raw bytes.
    private static func request(_ requestLine: String, headers: [String], body: Data = Data()) -> Data {
        var text = requestLine + "\r\n"
        for header in headers {
            text += header + "\r\n"
        }
        text += "\r\n"
        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    /// URLSession-style header order: Content-Length is NOT the last header.
    private static func toastHeaders(contentLength: Int, name: String = "Content-Length") -> [String] {
        [
            "Host: 127.0.0.1:45831",
            "Content-Type: application/json",
            "\(name): \(contentLength)",
            "X-NemoNotch-Token: deadbeef",
        ]
    }

    /// ①
    @Test("header block + Content-Length + empty body is NOT complete")
    func headersWithContentLengthAndEmptyBodyIsIncomplete() {
        let data = Self.request(
            "POST /v1/toast HTTP/1.1",
            headers: Self.toastHeaders(contentLength: Self.json.count)
        )
        #expect(HookServer.hasCompleteHTTPRequest(data) == false)
    }

    /// ②
    @Test("header block + Content-Length + first 5 body bytes is NOT complete")
    func partialBodyIsIncomplete() {
        let data = Self.request(
            "POST /v1/toast HTTP/1.1",
            headers: Self.toastHeaders(contentLength: Self.json.count),
            body: Self.json.prefix(5)
        )
        #expect(HookServer.hasCompleteHTTPRequest(data) == false)
    }

    /// ③
    @Test("header block + Content-Length + whole body is complete")
    func fullBodyIsComplete() {
        let data = Self.request(
            "POST /v1/toast HTTP/1.1",
            headers: Self.toastHeaders(contentLength: Self.json.count),
            body: Self.json
        )
        #expect(HookServer.hasCompleteHTTPRequest(data) == true)
    }

    /// ④
    @Test("a request without Content-Length is complete once the header block ends")
    func requestWithoutContentLengthIsCompleteAtHeaderEnd() {
        let data = Self.request("GET /health HTTP/1.1", headers: ["Host: 127.0.0.1:45831"])
        #expect(HookServer.hasCompleteHTTPRequest(data) == true)
    }

    /// ⑤a — cut INSIDE a multi-byte UTF-8 character: 2 of 3 bytes of "中".
    @Test("a body cut inside a multi-byte UTF-8 character is NOT complete")
    func multiByteBodyIsJudgedInBytes() {
        let body = Data("中".utf8) // E4 B8 AD
        #expect(body.count == 3)
        let data = Self.request(
            "POST /v1/toast HTTP/1.1",
            headers: Self.toastHeaders(contentLength: body.count),
            body: body.prefix(2)
        )
        #expect(HookServer.hasCompleteHTTPRequest(data) == false)
    }

    /// ⑤b — "中中" is 6 bytes but 2 Characters; a character-counting
    /// implementation would see 2 < 6 and never declare it complete.
    @Test("Content-Length counts bytes, not characters")
    func multiByteBodyCountsBytesNotCharacters() {
        let body = Data("中中".utf8)
        #expect(body.count == 6)
        let data = Self.request(
            "POST /v1/toast HTTP/1.1",
            headers: Self.toastHeaders(contentLength: body.count),
            body: body
        )
        #expect(HookServer.hasCompleteHTTPRequest(data) == true)
    }

    /// ⑥
    @Test("the Content-Length header name is case-insensitive")
    func contentLengthHeaderNameIsCaseInsensitive() {
        for name in ["content-length", "CONTENT-LENGTH", "cOnTeNt-LeNgTh"] {
            let empty = Self.request(
                "POST /v1/toast HTTP/1.1",
                headers: Self.toastHeaders(contentLength: Self.json.count, name: name)
            )
            #expect(HookServer.hasCompleteHTTPRequest(empty) == false, "\(name): empty body must be incomplete")
            let full = Self.request(
                "POST /v1/toast HTTP/1.1",
                headers: Self.toastHeaders(contentLength: Self.json.count, name: name),
                body: Self.json
            )
            #expect(HookServer.hasCompleteHTTPRequest(full) == true, "\(name): whole body must be complete")
        }
    }

    /// ⑦ — curl 8.7.1 (`-H … -H … -d`, hook-sender.sh's shape) always emits
    /// Content-Length as the LAST header. Guards against the one-line String
    /// fix, which is still always-true in exactly this shape.
    @Test("Content-Length as the LAST header (curl 8.7.1 order) is honored")
    func contentLengthAsLastHeaderIsHonored() {
        let headers = [
            "Host: 127.0.0.1:45831",
            "Content-Type: application/json",
            "X-NemoNotch-Token: deadbeef",
            "Content-Length: \(Self.json.count)",
        ]
        let empty = Self.request("POST /hook HTTP/1.1", headers: headers)
        #expect(HookServer.hasCompleteHTTPRequest(empty) == false)
        let full = Self.request("POST /hook HTTP/1.1", headers: headers, body: Self.json)
        #expect(HookServer.hasCompleteHTTPRequest(full) == true)
    }
}
