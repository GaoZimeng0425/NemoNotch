import Foundation
@testable import NemoNotch
import Testing

/// `record.data` fixtures shaped like real usernoted rows (Slack has
/// title/subtitle/body; WeChat with message details off has body only).
struct NotificationRecordTests {
    private static let uuidBytes = Data((0 ..< 16).map { UInt8($0) })

    private func plist(_ root: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    @Test func decodesSlackShape() throws {
        let data = try plist([
            "app": "com.tinyspeck.slackmacgap",
            "uuid": Self.uuidBytes,
            "date": 814_968_448.7,
            "req": ["titl": "王小明", "subt": "#design", "body": "hi"],
        ])
        let record = try #require(NotificationRecord.decode(data))
        #expect(record.bundleID == "com.tinyspeck.slackmacgap")
        #expect(record.id == UUID(uuidString: "00010203-0405-0607-0809-0A0B0C0D0E0F"))
        #expect(record.title == "王小明")
        #expect(record.subtitle == "#design")
        #expect(record.body == "hi")
        #expect(record.date == Date(timeIntervalSinceReferenceDate: 814_968_448.7))
    }

    @Test func decodesWeChatWithoutTitle() throws {
        let data = try plist([
            "app": "com.tencent.xinWeChat",
            "uuid": Self.uuidBytes,
            "date": 814_976_707.6,
            "req": ["body": "你收到了一条消息"],
        ])
        let record = try #require(NotificationRecord.decode(data))
        #expect(record.title == nil)
        #expect(record.subtitle == nil)
        #expect(record.body == "你收到了一条消息")
    }

    @Test func emptyStringsBecomeNil() throws {
        let data = try plist([
            "app": "com.apple.mail",
            "uuid": Self.uuidBytes,
            "date": 1.0,
            "req": ["titl": "", "subt": "", "body": "x"],
        ])
        let record = try #require(NotificationRecord.decode(data))
        #expect(record.title == nil)
        #expect(record.subtitle == nil)
    }

    @Test func rejectsMissingUUID() throws {
        let data = try plist(["app": "a", "date": 1.0, "req": ["body": "x"]])
        #expect(NotificationRecord.decode(data) == nil)
    }

    @Test func rejectsShortUUID() throws {
        let data = try plist(["app": "a", "uuid": Data(count: 8), "date": 1.0])
        #expect(NotificationRecord.decode(data) == nil)
    }

    @Test func rejectsMissingApp() throws {
        let data = try plist(["uuid": Self.uuidBytes, "date": 1.0])
        #expect(NotificationRecord.decode(data) == nil)
    }

    @Test func rejectsGarbage() {
        #expect(NotificationRecord.decode(Data("x".utf8)) == nil)
    }
}
