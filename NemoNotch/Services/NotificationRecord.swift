import Foundation

/// One Notification Center entry, decoded from a `record.data` binary plist
/// in usernoted's private database. Only the fields the toast needs.
///
/// Shape (macOS 26/27, observed): top-level `app` (bundle id, case may differ
/// from the app's own `CFBundleIdentifier`), `uuid` (16 bytes), `date`
/// (CFAbsoluteTime), and `req` with `titl` / `subt` / `body`.
struct NotificationRecord: Equatable {
    let id: UUID
    let bundleID: String
    let title: String?
    let subtitle: String?
    let body: String?
    let date: Date

    /// nil when the blob is not a plist or lacks `uuid` (16 bytes) / `app`.
    static func decode(_ data: Data) -> NotificationRecord? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let app = root["app"] as? String, !app.isEmpty,
              let uuidData = root["uuid"] as? Data, uuidData.count == 16
        else { return nil }
        let id = uuidData.withUnsafeBytes { raw in
            UUID(uuid: raw.loadUnaligned(as: uuid_t.self))
        }
        let req = root["req"] as? [String: Any] ?? [:]
        let date = (root["date"] as? Double).map(Date.init(timeIntervalSinceReferenceDate:)) ?? .distantPast
        return NotificationRecord(
            id: id,
            bundleID: app,
            title: nonEmpty(req["titl"]),
            subtitle: nonEmpty(req["subt"]),
            body: nonEmpty(req["body"]),
            date: date
        )
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
