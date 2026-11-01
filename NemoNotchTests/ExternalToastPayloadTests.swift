import Foundation
@testable import NemoNotch
import Testing

@Suite("ExternalToastPayload")
struct ExternalToastPayloadTests {
    private func json(_ s: String) -> Data {
        s.data(using: .utf8)!
    }

    @Test("full-field payload decodes, sf: icon stripped to symbol name")
    func fullFields() {
        let result = ExternalToastPayload.parse(json("""
        {"schema":1,"app":"MyDownloader","key":"download-42","title":"下载完成",
        "body":"nemo-1.2.3.dmg · 84 MB","icon":"sf:arrow.down.circle",
        "jumpBundleId":"com.me.mydownloader"}
        """))
        let expected = ExternalToastPayload(
            schema: 1,
            app: "MyDownloader",
            key: "download-42",
            title: "下载完成",
            body: "nemo-1.2.3.dmg · 84 MB",
            iconSymbol: "arrow.down.circle",
            jumpBundleId: "com.me.mydownloader"
        )
        #expect(result == .success(expected))
    }

    @Test("minimal payload (app + title) decodes with nil optionals")
    func minimalFields() {
        let result = ExternalToastPayload.parse(json(#"{"schema":1,"app":"Demo","title":"Hi"}"#))
        let expected = ExternalToastPayload(
            schema: 1, app: "Demo", key: nil, title: "Hi",
            body: nil, iconSymbol: nil, jumpBundleId: nil
        )
        #expect(result == .success(expected))
    }

    @Test("unknown fields are ignored (forward compatibility)")
    func unknownFieldsIgnored() {
        let result = ExternalToastPayload.parse(json(#"{"schema":1,"app":"Demo","title":"Hi","extra":1}"#))
        guard case let .success(payload) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(payload.app == "Demo")
        #expect(payload.title == "Hi")
    }

    @Test("schema 2 is rejected as badSchemaVersion")
    func rejectsSchema2() {
        let result = ExternalToastPayload.parse(json(#"{"schema":2,"app":"Demo","title":"Hi"}"#))
        #expect(result == .failure(.badSchemaVersion))
    }

    @Test("missing schema is rejected as badSchemaVersion")
    func rejectsMissingSchema() {
        let result = ExternalToastPayload.parse(json(#"{"app":"Demo","title":"Hi"}"#))
        #expect(result == .failure(.badSchemaVersion))
    }

    @Test("missing or empty app is rejected as appInvalid")
    func rejectsMissingOrEmptyApp() {
        #expect(ExternalToastPayload.parse(json(#"{"schema":1,"title":"Hi"}"#)) == .failure(.appInvalid))
        #expect(ExternalToastPayload.parse(json(#"{"schema":1,"app":"","title":"Hi"}"#)) == .failure(.appInvalid))
    }

    @Test("missing or empty title is rejected as titleInvalid")
    func rejectsMissingOrEmptyTitle() {
        #expect(ExternalToastPayload.parse(json(#"{"schema":1,"app":"Demo"}"#)) == .failure(.titleInvalid))
        #expect(ExternalToastPayload.parse(json(#"{"schema":1,"app":"Demo","title":""}"#)) == .failure(.titleInvalid))
    }

    @Test("length limits: app 49 / key 129 / title 121 / body 281 each rejected; boundary values accepted")
    func rejectsOverlongFields() {
        func payloadJSON(app: String = "Demo", key: String? = nil, title: String = "Hi", body: String? = nil) -> Data {
            var parts = [#""schema":1"#, #""app":"\#(app)""#]
            if let key {
                parts.append(#""key":"\#(key)""#)
            }
            parts.append(#""title":"\#(title)""#)
            if let body {
                parts.append(#""body":"\#(body)""#)
            }
            return json("{" + parts.joined(separator: ",") + "}")
        }

        #expect(ExternalToastPayload
            .parse(payloadJSON(app: String(repeating: "a", count: 49))) == .failure(.appTooLong))
        #expect(ExternalToastPayload
            .parse(payloadJSON(key: String(repeating: "k", count: 129))) == .failure(.keyTooLong))
        #expect(ExternalToastPayload
            .parse(payloadJSON(title: String(repeating: "t", count: 121))) == .failure(.titleTooLong))
        #expect(ExternalToastPayload
            .parse(payloadJSON(body: String(repeating: "b", count: 281))) == .failure(.bodyTooLong))

        let boundary = ExternalToastPayload.parse(payloadJSON(
            app: String(repeating: "a", count: 48),
            key: String(repeating: "k", count: 128),
            title: String(repeating: "t", count: 120),
            body: String(repeating: "b", count: 280)
        ))
        guard case .success = boundary else {
            Issue.record("expected boundary payload to pass, got \(boundary)")
            return
        }
    }

    @Test("'::' in app or key is rejected (collision-proof card keys)")
    func rejectsSeparatorInAppOrKey() {
        #expect(ExternalToastPayload
            .parse(json(#"{"schema":1,"app":"De::mo","title":"Hi"}"#)) == .failure(.separatorInAppOrKey))
        #expect(ExternalToastPayload
            .parse(json(#"{"schema":1,"app":"Demo","key":"a::b","title":"Hi"}"#)) == .failure(.separatorInAppOrKey))
    }

    @Test("icon without sf: prefix degrades to nil symbol, payload still succeeds")
    func iconWithoutPrefixDegrades() {
        let result = ExternalToastPayload.parse(json(#"{"schema":1,"app":"Demo","title":"Hi","icon":"hammer"}"#))
        guard case let .success(payload) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(payload.iconSymbol == nil)
    }

    @Test("malformed JSON is rejected as malformedJSON")
    func rejectsMalformedJSON() {
        #expect(ExternalToastPayload.parse(json("not json")) == .failure(.malformedJSON))
    }

    @Test("cardKey: keyed push is ext:<app>::<key>; keyless pushes get unique keys per makeUniqueID call")
    func cardKeyIdentity() {
        let keyed = ExternalToastPayload(
            schema: 1, app: "MyApp", key: "dl-1", title: "t",
            body: nil, iconSymbol: nil, jumpBundleId: nil
        )
        #expect(keyed.cardKey() == "ext:MyApp::dl-1")

        let keyless = ExternalToastPayload(
            schema: 1, app: "MyApp", key: nil, title: "t",
            body: nil, iconSymbol: nil, jumpBundleId: nil
        )
        var calls = 0
        let makeUniqueID = { () -> String in
            calls += 1
            return "uuid-\(calls)"
        }
        #expect(keyless.cardKey(makeUniqueID: makeUniqueID) == "ext:MyApp::uuid-1")
        #expect(keyless.cardKey(makeUniqueID: makeUniqueID) == "ext:MyApp::uuid-2")
        #expect(keyless.cardKey(makeUniqueID: makeUniqueID) != keyless.cardKey(makeUniqueID: makeUniqueID))
    }

    @Test("every rejection has a non-empty localized description")
    func rejectionDescriptions() {
        let all: [ExternalToastRejection] = [
            .malformedJSON, .badSchemaVersion, .appInvalid, .appTooLong, .keyTooLong,
            .separatorInAppOrKey, .titleInvalid, .titleTooLong, .bodyTooLong,
        ]
        for rejection in all {
            #expect(!rejection.localizedDescription.isEmpty)
        }
    }
}
