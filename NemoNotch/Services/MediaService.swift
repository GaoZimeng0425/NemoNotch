import AppKit
@preconcurrency import Foundation

private struct NowPlayingInfoBox: @unchecked Sendable {
    let info: [String: Any]?
    init(info: [String: Any]?) { self.info = info }
}

@MainActor
@Observable
final class MediaService {
    var playbackState = PlaybackState()
    var appIcon: NSImage?
    /// When non-nil, UI surfaces a banner prompting the user to grant
    /// Automation permission for this player in System Settings.
    var permissionDeniedPlayer: KnownPlayer?

    private var pollTimer: Timer?
    private var progressTimer: Timer?
    private var reconcileTask: Task<Void, Never>?
    private var isUpdatingNowPlaying = false
    private var needsFollowupUpdate = false
    private var needsFollowupValidation = false
    private var validationTask: Task<Void, Never>?
    private let remote = MediaRemote.shared
    private let nowPlayingCLI = NowPlayingCLI()

    init() {
        remote.registerForNotifications()
        remote.setCanBeNowPlayingApplication(false)
        MediaBridge.permissionDeniedCallback = { [weak self] bundleID in
            guard let self, let player = KnownPlayer(bundleID: bundleID) else { return }
            self.permissionDeniedPlayer = player
        }
        setupNotifications()
        startPolling()
        updateNowPlaying()
    }

    func dismissPermissionBanner() {
        permissionDeniedPlayer = nil
    }

    func openAutomationSettings() {
        MediaBridge.openAutomationSettings()
        permissionDeniedPlayer = nil
    }

    func togglePlayPause() {
        let bundleID = playbackState.appBundleIdentifier
        if MediaBridge.supportsSeeking(bundleID: bundleID) {
            MediaBridge.togglePlayPause(bundleID: bundleID)
        } else {
            remote.sendCommand(.togglePlayPause)
        }
    }

    func nextTrack() {
        let bundleID = playbackState.appBundleIdentifier
        applyTrackChangePlaceholder()
        if MediaBridge.supportsSeeking(bundleID: bundleID) {
            MediaBridge.nextTrack(bundleID: bundleID)
        } else {
            remote.sendCommand(.nextTrack)
        }
        scheduleReconcile(after: 0.6)
    }

    func previousTrack() {
        let bundleID = playbackState.appBundleIdentifier
        applyTrackChangePlaceholder()
        if MediaBridge.supportsSeeking(bundleID: bundleID) {
            MediaBridge.previousTrack(bundleID: bundleID)
        } else {
            remote.sendCommand(.previousTrack)
        }
        scheduleReconcile(after: 0.6)
    }

    /// Optimistic UI hint: zero progress and dim artwork until the real track
    /// metadata arrives. We keep the title so the user has continuity.
    private func applyTrackChangePlaceholder() {
        playbackState.position = 0
        playbackState.duration = 0
    }

    private func scheduleReconcile(after seconds: TimeInterval) {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.updateNowPlaying()
        }
    }

    var supportsSeeking: Bool {
        MediaBridge.supportsSeeking(bundleID: playbackState.appBundleIdentifier)
    }

    func skipForward(_ interval: Double = 15) {
        seek(by: interval)
    }

    func skipBackward(_ interval: Double = 15) {
        seek(by: -interval)
    }

    /// Drag-to-seek entry point used by the progress bar.
    func seek(toFraction fraction: Double) {
        guard playbackState.duration > 0 else { return }
        let target = max(0, min(playbackState.duration, fraction * playbackState.duration))
        seek(toAbsolute: target)
    }

    private func seek(by interval: Double) {
        guard playbackState.duration > 0 else { return }
        let target = max(0, min(playbackState.position + interval, playbackState.duration))
        seek(toAbsolute: target, fallbackInterval: interval)
    }

    private func seek(toAbsolute target: Double, fallbackInterval: Double? = nil) {
        let bundleID = playbackState.appBundleIdentifier
        playbackState.position = target

        if MediaBridge.supportsSeeking(bundleID: bundleID) {
            MediaBridge.setPlayerPosition(bundleID: bundleID, position: target)
        } else if remote.setElapsedTime(target) {
            // ok
        } else if let interval = fallbackInterval {
            remote.skip(interval: interval)
        }

        scheduleReconcile(after: 0.5)
    }

    deinit {
        MainActor.assumeIsolated {
            pollTimer?.invalidate()
            progressTimer?.invalidate()
            reconcileTask?.cancel()
        }
    }

    private func setupNotifications() {
        let nc = DistributedNotificationCenter.default()

        nc.addObserver(forName: .init("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
            }
        }

        nc.addObserver(forName: .init("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
            }
        }

        nc.addObserver(forName: .init("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
            }
        }

        nc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
            }
        }

        nc.addObserver(forName: .init("com.apple.Music.playerInfo"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
            }
        }
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateNowPlaying()
                self?.recheckPermissionIfBannerShown()
            }
        }
    }

    /// If the banner is up, probe whether the user has since granted access.
    /// On success, dismiss the banner silently.
    private func recheckPermissionIfBannerShown() {
        guard let player = permissionDeniedPlayer else { return }
        if MediaBridge.hasAutomationAccess(bundleID: player.rawValue) {
            permissionDeniedPlayer = nil
        }
    }

    private func updateProgressTimer(isPlaying: Bool) {
        if isPlaying && progressTimer == nil {
            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.playbackState.isPlaying, self.playbackState.duration > 0 else { return }
                    let next = min(self.playbackState.duration, self.playbackState.position + 0.5)
                    if next > self.playbackState.position { self.playbackState.position = next }
                }
            }
        } else if !isPlaying && progressTimer != nil {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func updateNowPlaying() {
        if isUpdatingNowPlaying {
            needsFollowupUpdate = true
            return
        }

        isUpdatingNowPlaying = true

        nowPlayingCLI.fetchNowPlayingInfo { [weak self] cliInfo in
            let box = NowPlayingInfoBox(info: cliInfo)
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyInfo(box.info)
                self.isUpdatingNowPlaying = false
                if self.needsFollowupUpdate {
                    self.needsFollowupUpdate = false
                    self.updateNowPlaying()
                }
            }
        }
    }

    private static func hasMetadata(_ info: [String: Any]) -> Bool {
        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        return !(title.isEmpty && artist.isEmpty)
    }

    private func mergePlaybackState(cliInfo: [String: Any]?, mrInfo: [String: Any]?) -> [String: Any]? {
        guard let cliInfo else { return mrInfo }
        guard let mrInfo else { return cliInfo }

        let cliRate = (cliInfo["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let mrRate = (mrInfo["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let cliPlaying = cliRate > 0
        let mrPlaying = mrRate > 0

        if cliPlaying != mrPlaying {
            var merged = cliInfo
            merged["kMRMediaRemoteNowPlayingInfoPlaybackRate"] = NSNumber(value: mrRate)
            return merged
        }

        return cliInfo
    }

    private func applyInfo(_ info: [String: Any]?) {
        guard let info, !info.isEmpty else {
            if !playbackState.isEmpty {
                playbackState = PlaybackState()
                appIcon = nil
            }
            updateProgressTimer(isPlaying: false)
            return
        }

        let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
        let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
        let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
        let duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? TimeInterval ?? 0
        var position = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? TimeInterval ?? 0
        let playbackRate = (info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? 0
        let isPlaying = playbackRate > 0

        if isPlaying, let timestamp = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date {
            let elapsed = Date().timeIntervalSince(timestamp)
            position = max(0, position + elapsed)
            if duration > 0 { position = min(position, duration) }
        }

        let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data

        if title.isEmpty && artist.isEmpty {
            if !playbackState.isEmpty {
                playbackState = PlaybackState()
                appIcon = nil
            }
            updateProgressTimer(isPlaying: false)
            return
        }

        let bundleID = info["kMRMediaRemoteNowPlayingInfoParentAppBundleID"] as? String
            ?? info["kMRMediaRemoteNowPlayingInfoAppBundleID"] as? String

        let previousBundleID = playbackState.appBundleIdentifier
        let resolvedBundleID = bundleID ?? previousBundleID

        playbackState = PlaybackState(
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            position: position,
            isPlaying: isPlaying,
            artworkData: artworkData,
            appBundleIdentifier: resolvedBundleID,
            appName: nil
        )

        if let resolvedBundleID, !resolvedBundleID.isEmpty {
            applyPlayingApp(bundleID: resolvedBundleID, changed: resolvedBundleID != previousBundleID)
        }
        updateProgressTimer(isPlaying: isPlaying)
    }

    private func applyPlayingApp(bundleID: String, changed: Bool) {
        // Only hit NSWorkspace (disk IO + Launch Services) when the bundleID
        // actually changes. Otherwise the cached icon/appName are still valid.
        guard changed else { return }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            appIcon = NSWorkspace.shared.icon(forFile: url.path)
            playbackState.appName = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName
        } else {
            appIcon = nil
        }
        MediaBridge.requestPermissionIfNeeded(bundleID: bundleID)
    }
}
