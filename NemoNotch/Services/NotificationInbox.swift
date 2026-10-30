import Foundation

/// What one app's notification toast card says. Single notification: sender
/// (+ channel) over the body. Several: the de-duplicated senders, newest
/// first, over "latest: sender — body".
struct NotificationCard: Equatable {
    let count: Int
    let line1: String?
    let line2: String?

    /// nil when `pending` is empty. `pending` need not be sorted.
    static func make(appName: String, pending: [NotificationRecord], latestPrefix: String) -> NotificationCard? {
        let newestFirst = pending.sorted { $0.date > $1.date }
        guard let latest = newestFirst.first else { return nil }
        if newestFirst.count == 1 {
            let heading = [latest.title, latest.subtitle].compactMap(\.self).joined(separator: " · ")
            return NotificationCard(count: 1, line1: heading.isEmpty ? nil : heading, line2: latest.body)
        }
        func sender(_ record: NotificationRecord) -> String {
            record.title ?? record.subtitle ?? appName
        }
        var seen = Set<String>()
        let senders = newestFirst.map(sender).filter { seen.insert($0).inserted }
        let latestText = [sender(latest), latest.body].compactMap(\.self).joined(separator: " — ")
        return NotificationCard(
            count: newestFirst.count,
            line1: senders.joined(separator: "、"),
            line2: latestPrefix + latestText
        )
    }
}

/// Pure bookkeeping between Notification Center reads: which records are
/// new, which the user already dealt with, and what each watched app still
/// has pending.
///
/// - The first successful read seeds the baseline — everything already in
///   Notification Center (every app, watched or not) counts as seen, so
///   launching, granting access late, or adding an app to the list never
///   floods the row with backlog.
/// - A record is pending while it is still in Notification Center, arrived
///   after the baseline for a watched app, and was not handled (card
///   clicked / closed / expired). A card evicted from the row is not
///   handled: its records ride along with the app's next card.
/// - App keys are lowercased: the database's `app` field and the app's own
///   bundle id can differ in case (`com.tencent.xinWeChat`).
struct NotificationInbox {
    private(set) var isSeeded = false
    private var seen = Set<UUID>()
    private var pendingByApp: [String: [NotificationRecord]] = [:]

    /// Feeds one successful read. Returns the (lowercased) watched apps that
    /// got at least one new record; records gone from `records` leave the
    /// pending sets.
    mutating func ingest(_ records: [NotificationRecord], watched: Set<String>) -> Set<String> {
        let present = Set(records.map(\.id))
        guard isSeeded else {
            isSeeded = true
            seen = present
            return []
        }
        for app in pendingByApp.keys {
            pendingByApp[app]?.removeAll { !present.contains($0.id) }
        }
        pendingByApp = pendingByApp.filter { !$0.value.isEmpty }

        var arrivals = Set<String>()
        for record in records where seen.insert(record.id).inserted {
            let app = record.bundleID.lowercased()
            guard watched.contains(app) else { continue }
            pendingByApp[app, default: []].append(record)
            arrivals.insert(app)
        }
        // Seen ids that left Notification Center can never come back.
        seen.formIntersection(present)
        return arrivals
    }

    func pending(for app: String) -> [NotificationRecord] {
        pendingByApp[app] ?? []
    }

    var appsWithPending: Set<String> {
        Set(pendingByApp.keys)
    }

    mutating func markHandled(app: String) {
        pendingByApp[app] = nil
    }

    mutating func reset() {
        self = NotificationInbox()
    }
}
