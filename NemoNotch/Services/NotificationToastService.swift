import AppKit
import Foundation

/// Turns new Notification Center messages from the apps the user picked
/// (default Mail / Slack / WeChat) into toast cards, one per app.
///
/// A background poller re-reads usernoted's database only when its files
/// change (2s stat), `NotificationInbox` decides what is new, and each app's
/// pending set becomes one `.notification` card in `CompletionFlashService`'s
/// row. A card the user closes, clicks or lets expire marks its notifications
/// handled; a card waiting off-row (or dropped from a full pile) does not.
@MainActor
@Observable
final class NotificationToastService {
    enum Status: Equatable {
        case idle // feature switched off
        case ok
        case noAccess
        case unavailable(String)
    }

    private(set) var status: Status = .idle

    private let settings: AppSettings
    private let flash: CompletionFlashService
    private var inbox = NotificationInbox()
    private var poller: NotificationCenterPoller?

    init(settings: AppSettings, flash: CompletionFlashService) {
        self.settings = settings
        self.flash = flash
        flash.onToastRemoved = { [weak self] item, _ in
            guard case let .notification(bundleID) = item.source else { return }
            self?.inbox.markHandled(app: bundleID.lowercased())
        }
        LogService.info("NotificationToastService init", category: "NotificationToast")
    }

    func start() {
        settingsChanged()
    }

    /// Call after the switch or the app list changes.
    func settingsChanged() {
        guard settings.notificationToastEnabled else {
            stop()
            return
        }
        let watched = watchedApps
        for app in inbox.appsWithPending where !watched.contains(app) {
            inbox.markHandled(app: app)
            flash.updateNotificationToast(key: Self.key(app), item: nil)
        }
        if poller == nil {
            let poller = NotificationCenterPoller { [weak self] result in
                Task { @MainActor [weak self] in self?.apply(result) }
            }
            poller.start()
            self.poller = poller
        }
    }

    private func stop() {
        poller?.stop()
        poller = nil
        for app in inbox.appsWithPending {
            flash.updateNotificationToast(key: Self.key(app), item: nil)
        }
        inbox.reset()
        setStatus(.idle)
    }

    // MARK: - Reads

    private func apply(_ result: NotificationCenterReadResult) {
        guard poller != nil else { return } // switched off while a read was in flight
        switch result {
        case .noAccess:
            setStatus(.noAccess)
        case let .unavailable(reason):
            setStatus(.unavailable(reason))
        case let .records(records):
            setStatus(.ok)
            let previous = inbox.appsWithPending
            let arrivals = inbox.ingest(records, watched: watchedApps)
            for app in arrivals {
                if let item = item(for: app) {
                    flash.showNotificationToast(item)
                }
            }
            // Content may have shrunk (notifications cleared elsewhere): update
            // in place without restarting the timer, shown or waiting off-row.
            for app in previous.subtracting(arrivals) {
                flash.updateNotificationToast(key: Self.key(app), item: item(for: app))
            }
        }
    }

    private func setStatus(_ new: Status) {
        guard status != new else { return }
        let old = status
        status = new
        switch new {
        case .noAccess:
            LogService.warn("Notification Center unreadable — Full Disk Access needed", category: "NotificationToast")
        case let .unavailable(reason):
            LogService.warn("Notification Center unavailable: \(reason)", category: "NotificationToast")
        default:
            LogService.info("Notification toast status \(old) → \(new)", category: "NotificationToast")
        }
    }

    // MARK: - Cards

    private var watchedApps: Set<String> {
        Set(settings.notificationToastApps.map { $0.lowercased() })
    }

    private static func key(_ app: String) -> String {
        "notify:\(app)"
    }

    private func item(for app: String) -> CompletionItem? {
        let pending = inbox.pending(for: app)
        // The user's list holds the app's real bundle id; the database's case may differ.
        let bundleID = settings.notificationToastApps.first { $0.lowercased() == app }
            ?? pending.first?.bundleID ?? app
        let name = Self.displayName(bundleID: bundleID)
        guard let card = NotificationCard.make(
            appName: name,
            pending: pending,
            latestPrefix: String(localized: "notification.toast.latest")
        ) else { return nil }
        var item = CompletionItem(name: name, source: .notification(bundleID: bundleID))
        item.key = Self.key(app)
        item.notice = card
        return item
    }

    static func displayName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}

/// Background 2s stat of the database files; reads only when they changed
/// (or while the last read failed, so a fresh Full Disk Access grant is
/// picked up without a relaunch). All mutable state is confined to `queue`.
private final class NotificationCenterPoller: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nemo.NemoNotch.notification-center", qos: .utility)
    private let deliver: @Sendable (NotificationCenterReadResult) -> Void
    private var timer: DispatchSourceTimer?
    private var lastFingerprint: [Int64]?
    private var lastReadSucceeded = false

    init(deliver: @escaping @Sendable (NotificationCenterReadResult) -> Void) {
        self.deliver = deliver
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func tick() {
        let fingerprint = NotificationCenterReader.fingerprint()
        if lastReadSucceeded, let fingerprint, fingerprint == lastFingerprint {
            return
        }
        let result = NotificationCenterReader.read()
        lastFingerprint = fingerprint
        if case .records = result {
            lastReadSucceeded = true
        } else {
            lastReadSucceeded = false
        }
        deliver(result)
    }
}
