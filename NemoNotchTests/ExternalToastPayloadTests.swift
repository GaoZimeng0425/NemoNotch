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
            jumpBundleId: "com.me.mydownloader",
            jumpURL: nil
        )
        #expect(result == .success(expected))
    }

    @Test("minimal payload (app + title) decodes with nil optionals")
    func minimalFields() {
        let result = ExternalToastPayload.parse(json(#"{"schema":1,"app":"Demo","title":"Hi"}"#))
        let expected = ExternalToastPayload(
            schema: 1, app: "Demo", key: nil, title: "Hi",
            body: nil, iconSymbol: nil, jumpBundleId: nil, jumpURL: nil
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
        #expect(ExternalToastPayload.parse(json(
            "{\"schema\":1,\"app\":\"Demo\",\"title\":\"Hi\",\"jumpBundleId\":\"\(String(repeating: "j", count: 256))\"}"
        )) == .failure(.jumpBundleIdTooLong))

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

        let jumpBoundary = ExternalToastPayload.parse(json(
            "{\"schema\":1,\"app\":\"Demo\",\"title\":\"Hi\",\"jumpBundleId\":\"\(String(repeating: "j", count: 255))\"}"
        ))
        guard case .success = jumpBoundary else {
            Issue.record("expected 255-char jumpBundleId to pass, got \(jumpBoundary)")
            return
        }
    }

    @Test("an empty-string key is treated as absent: keyless payload, unique card keys")
    func emptyKeyTreatedAsAbsent() {
        let result = ExternalToastPayload.parse(json(#"{"schema":1,"app":"Demo","key":"","title":"Hi"}"#))
        guard case let .success(payload) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(payload.key == nil)
        #expect(payload.cardKey(makeUniqueID: { "u1" }) == "ext:Demo::u1")
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
            body: nil, iconSymbol: nil, jumpBundleId: nil, jumpURL: nil
        )
        #expect(keyed.cardKey() == "ext:MyApp::dl-1")

        let keyless = ExternalToastPayload(
            schema: 1, app: "MyApp", key: nil, title: "t",
            body: nil, iconSymbol: nil, jumpBundleId: nil, jumpURL: nil
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

    @Test("jumpURL: https and custom scheme accepted, trimmed")
    func jumpURLAccepted() {
        let r1 = ExternalToastPayload
            .parse(json(#"{"schema":1,"app":"Pulse","title":"告警","jumpURL":"pulse://alerts/123"}"#))
        #expect((try? r1.get())?.jumpURL == "pulse://alerts/123")
        let r2 = ExternalToastPayload
            .parse(json(#"{"schema":1,"app":"Pulse","title":"告警","jumpURL":"  https://example.com/x?y=1  "}"#))
        #expect((try? r2.get())?.jumpURL == "https://example.com/x?y=1")
    }

    @Test("jumpURL: file scheme (any case), scheme-less and space-containing values are rejected")
    func jumpURLRejected() {
        for bad in ["file:///etc/hosts", "FILE:///x", "alerts/123", "pulse://a b"] {
            let r = ExternalToastPayload
                .parse(json("{\"schema\":1,\"app\":\"Pulse\",\"title\":\"告警\",\"jumpURL\":\"\(bad)\"}"))
            #expect(r == .failure(.jumpURLInvalid), "\(bad)")
        }
    }

    @Test("jumpURL over 2048 chars is rejected as jumpURLTooLong")
    func jumpURLTooLong() {
        let long = "https://e.com/" + String(repeating: "a", count: 2048)
        let r = ExternalToastPayload
            .parse(json("{\"schema\":1,\"app\":\"Pulse\",\"title\":\"告警\",\"jumpURL\":\"\(long)\"}"))
        #expect(r == .failure(.jumpURLTooLong))
    }

    @Test("empty or whitespace jumpURL means absent")
    func jumpURLEmptyIsNil() {
        for empty in ["", "   "] {
            let r = ExternalToastPayload
                .parse(json("{\"schema\":1,\"app\":\"Pulse\",\"title\":\"告警\",\"jumpURL\":\"\(empty)\"}"))
            #expect((try? r.get())?.jumpURL == nil, "[\(empty)]")
        }
    }

    @Test("every rejection has a non-empty localized description")
    func rejectionDescriptions() {
        let all: [ExternalToastRejection] = [
            .malformedJSON, .badSchemaVersion, .appInvalid, .appTooLong, .keyTooLong,
            .separatorInAppOrKey, .titleInvalid, .titleTooLong, .bodyTooLong, .jumpBundleIdTooLong,
            .jumpURLInvalid, .jumpURLTooLong, .actionInvalid, .closeRequiresKey, .toneInvalid,
            .herdrTerminalInvalid, .expiresAtInvalid, .expiresAtInPast, .infinityRequiresKey,
        ]
        for rejection in all {
            #expect(!rejection.localizedDescription.isEmpty)
        }
    }

    // MARK: - Herdr mod fields (tone / herdrTerminal / action / expiresAt)

    private func parse(
        _ body: String,
        now: Date = Date(timeIntervalSince1970: 1000)
    ) -> Result<ExternalToastPayload, ExternalToastRejection> {
        ExternalToastPayload.parse(json(body), now: now)
    }

    private func payload(_ body: String) -> ExternalToastPayload? {
        if case let .success(p) = parse(body) {
            return p
        }
        return nil
    }

    @Test("tone parses and maps onto the four reminder tones")
    func toneParses() {
        #expect(payload(#"{"schema":1,"app":"A","title":"T","tone":"approve"}"#)?.tone == .approve)
        #expect(ExternalToastTone.approve.reminderKind == .needsApproval)
        #expect(ExternalToastTone.done.reminderKind == .turnDone)
        #expect(ExternalToastTone.decide.reminderKind == .needsDecision)
        #expect(ExternalToastTone.error.reminderKind == .agentError)
    }

    @Test("unknown tone is rejected")
    func toneInvalidRejected() {
        #expect(parse(#"{"schema":1,"app":"A","title":"T","tone":"purple"}"#) == .failure(.toneInvalid))
    }

    @Test("herdrTerminal accepts local and machine-prefixed addresses verbatim")
    func herdrTerminalAccepts() {
        #expect(payload(#"{"schema":1,"app":"A","title":"T","herdrTerminal":"t9m"}"#)?.herdrTerminal == "t9m")
        #expect(payload(#"{"schema":1,"app":"A","title":"T","herdrTerminal":"vps/t7"}"#)?.herdrTerminal == "vps/t7")
    }

    @Test("herdrTerminal rejects option-like, empty, spaced, nested and overlong values")
    func herdrTerminalRejects() {
        for bad in ["-x", "-vps/t7", "", "t 7", "a/b/c", String(repeating: "a", count: 33)] {
            let body = #"{"schema":1,"app":"A","title":"T","herdrTerminal":"\#(bad)"}"#
            #expect(parse(body) == .failure(.herdrTerminalInvalid), "\(bad)")
        }
    }

    @Test("close needs app + key only; unknown action rejected")
    func closeNeedsKeyOnly() {
        let close = payload(#"{"schema":1,"app":"Herdr","key":"t7","action":"close"}"#)
        #expect(close?.action == .close)
        #expect(close?.key == "t7")
        #expect(parse(#"{"schema":1,"app":"Herdr","action":"close"}"#) == .failure(.closeRequiresKey))
        #expect(parse(#"{"schema":1,"app":"Herdr","key":"t7","action":"open"}"#) == .failure(.actionInvalid))
    }

    @Test("show (explicit or default) still requires a title")
    func showStillNeedsTitle() {
        #expect(parse(#"{"schema":1,"app":"A"}"#) == .failure(.titleInvalid))
        #expect(parse(#"{"schema":1,"app":"A","action":"show"}"#) == .failure(.titleInvalid))
        #expect(payload(#"{"schema":1,"app":"A","title":"T"}"#)?.action == .show)
    }

    @Test("expiresAt: future timestamp, keyed infinity; past, keyless infinity and wrong types rejected")
    func expiresAtForms() {
        #expect(payload(#"{"schema":1,"app":"A","title":"T","expiresAt":1060}"#)?.expiry
            == .at(Date(timeIntervalSince1970: 1060)))
        #expect(payload(#"{"schema":1,"app":"A","key":"k","title":"T","expiresAt":"infinity"}"#)?.expiry == .infinity)
        #expect(payload(#"{"schema":1,"app":"A","title":"T"}"#)?.expiry == nil)
        #expect(parse(#"{"schema":1,"app":"A","title":"T","expiresAt":"infinity"}"#) == .failure(.infinityRequiresKey))
        #expect(parse(#"{"schema":1,"app":"A","title":"T","expiresAt":900}"#) == .failure(.expiresAtInPast))
        #expect(parse(#"{"schema":1,"app":"A","title":"T","expiresAt":"soon"}"#) == .failure(.expiresAtInvalid))
        #expect(parse(#"{"schema":1,"app":"A","title":"T","expiresAt":true}"#) == .failure(.expiresAtInvalid))
    }
}
